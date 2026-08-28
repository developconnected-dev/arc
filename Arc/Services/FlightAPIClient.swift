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
        /// The provider's revised (estimated) arrival, when one is published.
        /// Kept apart from `arr_actual`, which since the runway-time fix means
        /// a CONFIRMED landing — an estimate must never impersonate a fact.
        /// Optional with a default: older backends don't send it.
        var arr_estimated: String? = nil
        /// The provider's estimated wheels-up, while it is still unconfirmed
        /// — what the departure hedge is measured against instead of the
        /// gate time (see DepartureEvidence).
        var dep_runway_estimated: String? = nil
        /// Whether the provider has live coverage of this departure. Without
        /// it, no take-off confirmation will ever arrive.
        var dep_live: Bool? = nil
        /// Where the aircraft actually is, per the provider's own position
        /// block. A second witness to the gate-to-runway question that needs
        /// no ADS-B aggregator — which matters because the aggregators are
        /// unreachable from the Worker and can be unreachable from a device
        /// on a restricted network too.
        var position: ProviderPosition? = nil
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

        // MARK: Ground and water legs
        //
        // All optional with defaults, so a flight payload — which carries none
        // of them — decodes exactly as before, and so an older backend that has
        // never heard of trains keeps working against a newer app.

        /// "air", "rail" or "sea". Absent means air.
        var mode: String? = nil
        /// "live", "scheduled" or "manual" — how much the source actually knows.
        var data_tier: String? = nil
        /// The provider's own endpoint handle: a MOTIS stop id, or a port name.
        /// Long and opaque; never rendered.
        var dep_stop_id: String? = nil
        var arr_stop_id: String? = nil
        /// IANA zone per endpoint. The airport table cannot answer for a station
        /// or a port, so the backend resolves these and sends them.
        var dep_tz: String? = nil
        var arr_tz: String? = nil
        /// The platform originally advertised, when it differs from the current
        /// one. The pair is what makes a platform change visible.
        var dep_gate_scheduled: String? = nil
        var vessel_name: String? = nil
        var vessel_mmsi: String? = nil
        var operator_logo: String? = nil
        var disruption_note: String? = nil
        var booking_url: String? = nil
        /// MOTIS trip id — a fast path only. It embeds a per-import sequence the
        /// feed renumbers, so it is re-resolved rather than trusted forever.
        var trip_id: String? = nil
        /// The real routed path as [[lat, lon], …], already simplified by the
        /// backend. Absent for flights and ferries, which fall back to an arc.
        var route_path: [[Double]]? = nil
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

    // MARK: - Trips that aren't flights
    //
    // Rail comes from Transitous (community MOTIS, no key), sea from
    // Ferryhopper. Both are normalised by the Worker into the SAME
    // FlightSearchResult shape a flight arrives in, so everything downstream —
    // the list, the detail sheet, the widget, the Live Activity — needs no idea
    // which of the three it is holding.

    private func get<T: Decodable>(_ path: String, _ items: [URLQueryItem]) async throws -> T {
        let url = baseURL.appending(path: path).appending(queryItems: items)
        let (data, _) = try await session.data(from: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    struct ModeGuess: Codable, Sendable {
        let mode: String
        let confidence: Double
        let reason: String
    }
    private struct ClassifyResponse: Codable, Sendable {
        let modes: [String]
        let ranked: [ModeGuess]
    }

    /// Which kinds of journey a query might mean, most likely first.
    ///
    /// Arc has one search box and no mode picker, so the query itself has to say
    /// what it is. Several designators genuinely mean different things in
    /// different modes — "FR 9612" is both a Ryanair flight and a Frecciarossa —
    /// so this can legitimately return more than one, and the caller is meant to
    /// search all of them rather than pick.
    func classify(query: String) async -> [String] {
        do {
            let r: ClassifyResponse = try await get("/classify", [.init(name: "q", value: query)])
            return r.modes
        } catch {
            // Never block a search on the classifier: searching all three is
            // slower but always correct, which is the right way to fail.
            return ["air", "rail", "sea"]
        }
    }

    // MARK: Rail

    struct TransitStop: Codable, Sendable, Identifiable {
        let id: String
        let name: String
        let lat: Double?
        let lon: Double?
        let country: String?
        let tz: String?
    }

    func railStations(query: String) async throws -> [TransitStop] {
        try await get("/rail/stations", [.init(name: "q", value: query)])
    }

    struct RailDeparture: Codable, Sendable, Identifiable {
        let trip_id: String
        let service: String
        let `operator`: String
        let headsign: String
        let mode: String
        /// The stop as the BOARD names it. This — not the id used to query the
        /// board — is what matches the trip response, so it is what gets stored.
        let stop_id: String
        let stop_name: String
        let scheduled: String
        let expected: String
        let track: String?
        let realtime: Bool
        var id: String { trip_id }
    }

    func railDepartures(stopId: String, at date: Date = .now, limit: Int = 20)
        async throws -> [RailDeparture] {
        try await get("/rail/departures", [
            .init(name: "stopId", value: stopId),
            .init(name: "time", value: ISO8601DateFormatter().string(from: date)),
            .init(name: "n", value: String(limit)),
        ])
    }

    /// One booked service as a leg, sliced to the part actually travelled.
    ///
    /// `from`/`to` are the boarding and alighting stops. Passing them matters:
    /// ICE 373 runs to Chur, so a Basel passenger who omits `to` gets a card
    /// claiming they are going to Chur.
    func railTrip(tripId: String, from: String? = nil, to: String? = nil)
        async throws -> [FlightSearchResult] {
        var items = [URLQueryItem(name: "tripId", value: tripId)]
        if let from { items.append(.init(name: "from", value: from)) }
        if let to { items.append(.init(name: "to", value: to)) }
        return try await get("/rail/trip", items)
    }

    private struct ReresolveResponse: Codable, Sendable { let trip_id: String? }

    /// Find today's trip id for a service whose stored one has gone stale.
    ///
    /// MOTIS trip ids embed a per-import sequence that a feed rebuild renumbers,
    /// so a train added weeks ahead eventually stops resolving. `key` is the
    /// stable identity — operator, number, boarding stop, scheduled time.
    func railReresolve(stopId: String, key: String, at date: Date) async -> String? {
        let r: ReresolveResponse? = try? await get("/rail/reresolve", [
            .init(name: "stopId", value: stopId),
            .init(name: "key", value: key),
            .init(name: "time", value: ISO8601DateFormatter().string(from: date)),
        ])
        return r?.trip_id
    }

    // MARK: Sea

    struct Port: Codable, Sendable, Identifiable {
        let name: String
        let code: String
        let country: String
        /// nil outside Arc's waters — the backend leaves it unresolved rather
        /// than guessing an hour it can't stand behind.
        let tz: String?
        var id: String { code.isEmpty ? name : code }
    }

    func ferryPorts(query: String) async throws -> [Port] {
        try await get("/ferry/ports", [.init(name: "q", value: query)])
    }

    /// Sailings on a crossing. `from`/`to` are port NAMES — Ferryhopper resolves
    /// names and rejects codes ("PIR" finds nothing, "Piraeus" finds seven).
    func ferrySearch(from: String, to: String, date: String)
        async throws -> [FlightSearchResult] {
        try await get("/ferry/search", [
            .init(name: "from", value: from),
            .init(name: "to", value: to),
            .init(name: "date", value: date),
        ])
    }

    private struct SeaRouteResponse: Codable, Sendable { let route_path: [[Double]]? }

    /// The line a sailing between two ports follows, from OpenStreetMap's ferry
    /// network (the same lines Apple Maps draws between islands). nil when OSM
    /// has no line for the pair — the map then draws its straight fallback.
    func ferryRoute(from: (lat: Double, lon: Double), to: (lat: Double, lon: Double)) async -> [[Double]]? {
        let r: SeaRouteResponse? = try? await get("/ferry/route", [
            .init(name: "from", value: "\(from.lat),\(from.lon)"),
            .init(name: "to", value: "\(to.lat),\(to.lon)"),
        ])
        guard let path = r?.route_path, path.count >= 3 else { return nil }
        return path
    }

    // MARK: - Arrival stand

    /// Gate, terminal and belt for one flight, off an airport's FIDS board.
    ///
    /// The flight-by-number endpoint never carries an arrival gate — and at
    /// some airports no departure gate either (easyJet out of Basel); the
    /// airport FIDS feed does, but only where the airport publishes stands —
    /// Frankfurt does, Zurich and Heathrow don't. So this legitimately returns
    /// nil a lot, and callers must treat "no gate" as normal rather than as an
    /// error.
    struct Stand: Codable, Sendable {
        let flight: String
        let gate: String?
        let terminal: String?
        let belt: String?
    }

    /// `from`/`to` must be LOCAL to the airport — the backend has no
    /// timezone database, the app does.
    private func stand(icao: String, flight: String, direction: String,
                       around: Date, timeZone: TimeZone) async -> Stand? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.timeZone = timeZone

        // A window either side of the scheduled movement, so an early or late
        // aircraft is still inside it.
        let url = baseURL.appending(path: "/arrival-gate").appending(queryItems: [
            .init(name: "icao", value: icao.uppercased()),
            .init(name: "flight", value: flight.replacingOccurrences(of: " ", with: "").uppercased()),
            .init(name: "from", value: formatter.string(from: around.addingTimeInterval(-45 * 60))),
            .init(name: "to", value: formatter.string(from: around.addingTimeInterval(45 * 60))),
            .init(name: "direction", value: direction),
        ])
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Stand.self, from: data)
    }

    func arrivalStand(icao: String, flight: String,
                      arrival: Date, timeZone: TimeZone) async -> Stand? {
        await stand(icao: icao, flight: flight, direction: "Arrival",
                    around: arrival, timeZone: timeZone)
    }

    /// The departure gate off the origin's own board — asked only while the
    /// by-number record has none (see FlightTracker.backfillDepartureGate).
    func departureStand(icao: String, flight: String,
                        departure: Date, timeZone: TimeZone) async -> Stand? {
        await stand(icao: icao, flight: flight, direction: "Departure",
                    around: departure, timeZone: timeZone)
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

    // MARK: - Live Position (ADS-B, via the Worker's /position)

    /// The provider's own position for a leg, in the units Arc speaks
    /// (metres, m/s). `on_ground` is derived server-side from the reported
    /// altitude — see `adbPositionToSample` in the Worker.
    struct ProviderPosition: Codable, Sendable {
        let on_ground: Bool
        let velocity: Double
        let altitude: Double
        let lat: Double?
        let lon: Double?
        let reportedAt: String
    }

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
        if !workerHasNoADSB {
            let url = baseURL.appending(path: "/position").appending(queryItems: items)
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let pos = try? JSONDecoder().decode(LivePosition.self, from: data) {
                return pos
            }
            // The Worker can only read ADS-B once a source has whitelisted
            // it: Cloudflare's shared egress IPs are rate-limited or blocked
            // for anonymous callers. Stop asking for the rest of the session
            // and read the aircraft from here instead — this device has its
            // own address, which is the whole reason it can.
            workerHasNoADSB = true
        }
        return await Self.directADSB(icao24: icao24, registration: registration)
    }

    /// Ask the community aggregators directly. Same readsb payload from each;
    /// one of them names the array `aircraft` rather than `ac`.
    private static let adsbHosts = [
        (base: "https://api.adsb.lol", prefix: "/v2"),
        (base: "https://opendata.adsb.fi", prefix: "/api/v2"),
    ]
    /// Actor-isolated: one flag per session, flipped the first time the
    /// Worker admits it cannot read ADS-B.
    private var workerHasNoADSB = false

    private static func directADSB(icao24: String?, registration: String?) async -> LivePosition? {
        var lookups: [(String, String)] = []
        if let icao24, !icao24.isEmpty { lookups.append(("icao", icao24)) }
        if let registration, !registration.isEmpty { lookups.append(("reg", registration)) }
        for host in adsbHosts {
            for (kind, value) in lookups {
                let key = value.trimmingCharacters(in: .whitespaces).lowercased()
                guard !key.isEmpty,
                      let url = URL(string: "\(host.base)\(host.prefix)/\(kind)/\(key)") else { continue }
                var request = URLRequest(url: url)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                // The aggregators refuse anonymous-looking callers outright.
                request.setValue("ArcFlightTracker/1.0 (+https://arc.app)", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 10
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let raw = try? JSONDecoder().decode(ADSBResponse.self, from: data),
                      let ac = (raw.ac ?? raw.aircraft ?? []).first(where: { $0.lat != nil && $0.lon != nil })
                else { continue }
                return ac.asLivePosition
            }
        }
        return nil
    }

    private struct ADSBResponse: Decodable {
        let ac: [ADSBAircraft]?
        let aircraft: [ADSBAircraft]?
    }

    private struct ADSBAircraft: Decodable {
        let hex: String?
        let r: String?
        let lat: Double?
        let lon: Double?
        let gs: Double?
        let track: Double?
        let seen_pos: Double?
        /// feet, or the string "ground" when it is on the deck.
        let alt_baro: AltBaro?

        enum AltBaro: Decodable {
            case feet(Double), ground
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let d = try? c.decode(Double.self) { self = .feet(d) }
                else { self = .ground }
            }
            var isGround: Bool { if case .ground = self { return true }; return false }
            var metres: Double { if case .feet(let f) = self { return f * 0.3048 }; return 0 }
        }

        var asLivePosition: LivePosition {
            LivePosition(
                icao24: (hex ?? "").uppercased(),
                lat: lat ?? 0, lon: lon ?? 0,
                altitude: alt_baro?.metres ?? 0,
                velocity: (gs ?? 0) * 0.514444,
                heading: track ?? 0,
                on_ground: alt_baro?.isGround ?? false,
                registration: r,
                age_seconds: seen_pos.map { Int($0.rounded()) })
        }
    }

    /// This airport's learned taxi-out for an hour of the day — the grace a
    /// departure gets before Arc presumes it is airborne.
    func taxiPrior(iata: String, hourUTC: Int) async -> Int? {
        guard !iata.isEmpty else { return nil }
        let url = baseURL.appending(path: "/taxi/prior").appending(queryItems: [
            .init(name: "iata", value: iata),
            .init(name: "hour", value: String(hourUTC)),
        ])
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let result = try? JSONDecoder().decode(TaxiPrior.self, from: data) else { return nil }
        return result.minutes
    }

    struct TaxiPrior: Codable, Sendable {
        let minutes: Int
        let samples: Int
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

    /// What the flywheel knows about a flight number's usual gate at an
    /// airport, per the Worker's `/gates/predict`.
    struct GatePrediction: Codable, Sendable {
        let gate: String?
        let terminal: String?
        let agreeing: Int
        let samples: Int
        let confidence: Double

        /// One bar for every consumer (flight detail, Connection Assistant):
        /// below three sightings or half agreement, the "usual gate" is noise
        /// rather than a pattern, and showing it would be inventing a fact.
        var isConfident: Bool {
            gate?.isEmpty == false && samples >= 3 && confidence >= 0.5
        }
    }

    /// The observed-gate history's verdict for one flight at one airport.
    /// `direction` is "dep" or "arr" — which end of the leg the airport is.
    func gatePrediction(flight: String, airport: String,
                        direction: String) async -> GatePrediction? {
        let url = baseURL.appending(path: "/gates/predict").appending(queryItems: [
            .init(name: "flight", value: flight.replacingOccurrences(of: " ", with: "")),
            .init(name: direction, value: airport),
        ])
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(GatePrediction.self, from: data)
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

    /// Record that Arc predicted a delay before the airline published one.
    ///
    /// The value of this record is its TIMESTAMP: the cron stamps the moment
    /// the airline's own number catches up, and the gap between the two is the
    /// only speed claim Arc can honestly make. The Worker ignores duplicates,
    /// so re-polling the same prediction cannot reset the clock — call it
    /// freely, only the first one counts.
    ///
    /// Fire-and-forget, like every other measurement call: a flight tracker
    /// must not get slower or fail because a statistic could not be filed.
    func recordDelayPrediction(flightNumber: String, scheduledDeparture: Date,
                               predictedMinutes: Int, officialMinutes: Int,
                               reason: String?, userId: String) async {
        let iso = ISO8601DateFormatter()
        var body: [String: Any] = [
            "flight_number": flightNumber,
            "scheduled_departure": iso.string(from: scheduledDeparture),
            "predicted_minutes": predictedMinutes,
            "official_minutes": officialMinutes,
            "user_id": userId,
        ]
        if let reason { body["reason"] = reason }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        await postJSON(path: "/delay-prediction", data: data)
    }

    func unregisterLiveActivityToken(_ token: String) async {
        guard let data = try? JSONSerialization.data(withJSONObject: ["token": token]) else { return }
        await postJSON(path: "/la/unregister", data: data)
    }

    /// Ask the Worker to bring one friend's flight up to date, right now.
    ///
    /// The viewing device has a working connection — that is why someone is
    /// looking — but it cannot write `shared_flights` itself: RLS lets a friend
    /// read the row and only its owner change it, which is correct. So it asks
    /// the Worker, which holds the service key, re-checks the friendship and
    /// applies exactly the merge rules the cron would have applied.
    ///
    /// Returns whether the row was touched; the caller then re-reads it through
    /// the normal Supabase path rather than trusting a second shape here.
    func refreshFriendFlight(id: String) async -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": id]) else { return false }
        return await postJSON(path: "/shared/refresh", data: data)
    }

    /// This DEVICE's APNs token, which outlives any one Live Activity — the
    /// channel by which a cancellation the night before reaches a closed app.
    /// Returns whether the Worker accepted it: on a refusal the device keeps
    /// posting its own local alerts rather than going quiet.
    func registerDeviceToken(_ bodyJSON: Data) async -> Bool {
        await postJSON(path: "/push/register", data: bodyJSON)
    }

    func unregisterDeviceToken(_ token: String) async {
        guard let data = try? JSONSerialization.data(withJSONObject: ["token": token]) else { return }
        await postJSON(path: "/push/unregister", data: data)
    }

    @discardableResult
    private func postJSON(path: String, data: Data) async -> Bool {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Gate contributions are authenticated writes now — the Worker
        // refuses anonymous ones (anyone could wipe an airport's gate map).
        if let token = await MainActor.run(body: { ArcSupabase.shared.bearerToken }) {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = data
        // Best-effort: on failure the cron simply won't know about us.
        guard let (_, response) = try? await session.data(for: req) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
