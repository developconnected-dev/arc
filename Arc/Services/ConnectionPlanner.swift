import Foundation
import CoreLocation

/// Connection Assistant — pure, unit-testable logic. Detects connections
/// between the user's flights, breaks the transfer into concrete steps with
/// typical times, and rates the risk live as delays move the layover around.
///
/// Honest scope: step times are tiered heuristics (control area, airport size,
/// aircraft size, terminal change), not a per-airport procedure database — the
/// risk tiers are calibrated to be conservative rather than precise. What the
/// steps THEMSELVES claim is a different matter and is meant to be true: a
/// transfer that meets no passport desk must not be told that it will.
enum ConnectionPlanner {

    struct Step: Equatable {
        let name: String
        let icon: String
        let minutes: Int
        /// Where this number came from, when it came from something better than
        /// a tier — "610 m, gate to gate", "live queue · 4m ago", "usually B24".
        /// nil means the estimate is a heuristic and the card shouldn't dress it
        /// up as anything more.
        var detail: String? = nil
    }

    /// Everything the planner would rather measure than guess, gathered off the
    /// network by `ConnectionInsights` and injected here so the planner itself
    /// stays pure and testable.
    ///
    /// Every field is optional on purpose: each one independently upgrades a
    /// step from a tier to a measurement, and an absent one silently leaves the
    /// old heuristic in place. A connection at an airport Arc has no gate map
    /// for, for a flight it has never seen, still gets a sane answer.
    struct Context: Equatable {
        /// Straight-line metres between the two gates.
        var gateDistanceMeters: Double?
        var fromGate: String?
        var toGate: String?
        /// True when the gates came from observed history rather than a real
        /// assignment — the walk is then a likelihood, and must say so.
        var gatesPredicted: Bool = false
        /// Live security queue at the connecting airport, and whether it is an
        /// actual measurement rather than a time-of-day guess.
        var securityMinutes: Int?
        var securityIsLive: Bool = false
        var securityAgeMinutes: Int?

        init() {}
    }

    enum Risk: String {
        case relaxed = "Relaxed"
        case normal = "Normal"
        case tight = "Tight"
        case risky = "Risky"
    }

    struct Plan {
        let inbound: Flight
        let outbound: Flight
        let steps: [Step]
        let neededMinutes: Int      // sum of steps
        let layoverMinutes: Int     // live: outbound effective dep − inbound effective arr
        let risk: Risk
        /// Why this transfer skips border formalities, when it does — the
        /// reassuring half of the answer, and the half a step list can't give.
        let borderNote: String?
        /// The airport's own published floor for this kind of transfer, and
        /// whether the layover clears it. nil when the airport isn't in the
        /// table — no cross-check beats a made-up one.
        let publishedMinimum: Int?

        /// Below the airport's own minimum, this connection isn't one anybody
        /// would sell on a single ticket — worth saying outright, because a
        /// self-connected passenger who misses it is rebooked at their own cost.
        var isBelowPublishedMinimum: Bool {
            guard let publishedMinimum else { return false }
            return layoverMinutes < publishedMinimum
        }
    }

    // MARK: - Border control areas

    /// Which border-control area an airport sits in.
    ///
    /// Comparing COUNTRIES is the wrong test for "will I meet a passport desk",
    /// and it was wrong in both directions: Syros → Athens → Munich changes
    /// country and meets no border at all, because Greece and Germany are both
    /// inside Schengen, while Dublin → London changes country and meets none
    /// either. The control area is what a passenger actually walks through.
    enum BorderArea: Hashable {
        case schengen
        case commonTravelArea
        case country(String)
    }

    /// Schengen members, ISO-3166-1 alpha-2 as the bundled airport table spells
    /// them. Bulgaria and Romania are included — their AIR borders joined in
    /// March 2024, and this only ever reasons about airports. Monaco, San
    /// Marino and the Vatican run no controls of their own.
    private static let schengenCountries: Set<String> = [
        "AT", "BE", "BG", "CH", "CZ", "DE", "DK", "EE", "ES", "FI", "FR", "GR",
        "HR", "HU", "IS", "IT", "LI", "LT", "LU", "LV", "MT", "NL", "NO", "PL",
        "PT", "RO", "SE", "SI", "SK", "MC", "SM", "VA",
    ]

    /// The UK, Ireland and the Crown Dependencies — no immigration control
    /// between them.
    private static let commonTravelAreaCountries: Set<String> = ["GB", "IE", "IM", "JE", "GG"]

    /// Countries that put EVERY international arrival through immigration,
    /// baggage reclaim and customs before it may fly on — connecting or not.
    /// The most expensive thing a connection can hide, and entirely invisible
    /// to a country-vs-country comparison.
    private static let reclaimsBagsOnArrival: Set<String> = ["US", "CA"]

    /// nil when the code isn't a known airport — a rail stop, a port, or simply
    /// missing from the bundled table. Callers must treat that as "can't tell"
    /// rather than "no border", so an unresolved code never invents a desk.
    static func borderArea(of code: String) -> BorderArea? {
        guard let country = ReferenceData.shared.airport(code)?.country.uppercased(),
              !country.isEmpty else { return nil }
        if schengenCountries.contains(country) { return .schengen }
        if commonTravelAreaCountries.contains(country) { return .commonTravelArea }
        return .country(country)
    }

    private static func countryCode(_ code: String) -> String? {
        ReferenceData.shared.airport(code)?.country.uppercased()
    }

    /// Two flights form a connection when the first lands where the second
    /// departs, with a same-journey-plausible gap (30 min – 24 h).
    static func detectConnection(from flights: [Flight]) -> (inbound: Flight, outbound: Flight)? {
        let relevant = flights
            .filter { $0.isUpcoming || $0.isActive }
            .sorted { $0.scheduledDeparture < $1.scheduledDeparture }
        guard relevant.count >= 2 else { return nil }
        for i in 0..<(relevant.count - 1) {
            let a = relevant[i], b = relevant[i + 1]
            guard a.arrivalIATA.uppercased() == b.departureIATA.uppercased() else { continue }
            let gap = b.scheduledDeparture.timeIntervalSince(a.scheduledArrival) / 60
            if gap >= 30 && gap <= 24 * 60 { return (a, b) }
        }
        return nil
    }

    /// How this transfer reads to an MCT table: one country, one control area,
    /// or across a control boundary.
    static func transferKind(inbound: Flight, outbound: Flight) -> AirportConnectTimes.Transfer {
        let codes = [inbound.departureIATA, inbound.arrivalIATA, outbound.arrivalIATA]
        let countries = Set(codes.compactMap(countryCode))
        let areas = Set(codes.compactMap(borderArea(of:)))
        if areas.count > 1 { return .areaCrossing }
        if countries.count > 1 { return .withinArea }
        return .domestic
    }

    static func plan(inbound: Flight, outbound: Flight, context: Context = Context()) -> Plan {
        let steps = transferSteps(inbound: inbound, outbound: outbound, context: context)
        let needed = steps.reduce(0) { $0 + $1.minutes }
        let layover = Int(outbound.effectiveDeparture.timeIntervalSince(inbound.effectiveArrival) / 60)
        return Plan(inbound: inbound, outbound: outbound,
                    steps: steps, neededMinutes: needed,
                    layoverMinutes: layover,
                    risk: risk(neededMinutes: needed, layoverMinutes: layover),
                    borderNote: borderNote(inbound: inbound, outbound: outbound),
                    publishedMinimum: AirportConnectTimes.publishedMinimum(
                        at: inbound.arrivalIATA,
                        transfer: transferKind(inbound: inbound, outbound: outbound)))
    }

    /// Minutes to walk a measured gate-to-gate distance.
    ///
    /// Straight line understates the walk — terminals aren't corridors, and a
    /// passenger goes around piers, up escalators and sometimes onto a transit
    /// train — so the distance is inflated before it's converted. ~75 m/min is
    /// a brisk walk with hand luggage, not a run and not a stroll.
    static func walkMinutes(meters: Double) -> Int {
        let walked = meters * 1.35
        return max(3, Int((walked / 75).rounded()))
    }

    /// The step list a passenger actually walks through, in order.
    static func transferSteps(inbound: Flight, outbound: Flight,
                              context: Context = Context()) -> [Step] {
        var steps: [Step] = []

        let type = (inbound.aircraftType ?? "").uppercased()
        let widebody = ["747", "777", "787", "A330", "A340", "A350", "A380", "767"]
            .contains { type.contains($0) }
        // A 70-seat turboprop off an island hop empties long before a narrowbody
        // does, and that is exactly the leg most likely to be feeding a tight
        // connection — so it earns its own tier instead of the 12-minute default.
        let regional = ["ATR", "DASH", "DHC", "CRJ", "EMBRAER", "ERJ", "E170", "E175",
                        "E190", "E195", "SAAB", "DORNIER"].contains { type.contains($0) }
        let deplane = widebody ? 18 : (regional ? 8 : 12)
        steps.append(Step(name: "Deplane", icon: "figure.walk.departure", minutes: deplane))

        let hubIATAs: Set<String> = ["FRA", "CDG", "AMS", "LHR", "IST", "MUC", "MAD", "BCN",
                                     "FCO", "JFK", "EWR", "ORD", "ATL", "DFW", "LAX", "DXB",
                                     "DOH", "SIN", "HND", "ICN", "PEK", "PVG"]
        let hub = inbound.arrivalIATA.uppercased()
        let bigAirport = hubIATAs.contains(hub)

        let differentTerminals = inbound.arrivalTerminal != nil
            && outbound.departureTerminal != nil
            && inbound.arrivalTerminal != outbound.departureTerminal

        // A measured gate-to-gate distance replaces BOTH walking tiers, because
        // it already spans the whole journey from one aircraft door to the
        // other. Guessing "transfer walk" and "walk to gate" separately is only
        // necessary while we don't know where either gate is.
        let measuredWalk = context.gateDistanceMeters.map(walkMinutes(meters:))
        if let measuredWalk, let from = context.fromGate, let to = context.toGate {
            let distance = Int((context.gateDistanceMeters ?? 0).rounded())
            let provenance = context.gatesPredicted
                ? "\(distance) m · gates \(from)–\(to) are the usual pair"
                : "\(distance) m, gate to gate"
            steps.append(Step(name: "Walk \(from) → \(to)", icon: "figure.walk",
                              minutes: measuredWalk, detail: provenance))
        } else if differentTerminals {
            steps.append(Step(name: "Terminal change", icon: "bus", minutes: bigAirport ? 20 : 12))
        } else {
            steps.append(Step(name: "Transfer walk", icon: "figure.walk", minutes: bigAirport ? 14 : 8))
        }

        let origin = borderArea(of: inbound.departureIATA)
        let connection = borderArea(of: inbound.arrivalIATA)
        let destination = borderArea(of: outbound.arrivalIATA)
        // Unresolved endpoints are dropped rather than counted as different —
        // "I don't know where this is" must never manufacture a border.
        let known = [origin, connection, destination].compactMap { $0 }
        let crossesControl = Set(known).count > 1

        // Arriving from outside the hub's own control area, into a country that
        // makes every arrival clear immigration and customs with its bags.
        let arrivesFromOutside = origin != nil && connection != nil && origin != connection
        let reclaimsBags = arrivesFromOutside
            && (countryCode(hub).map(reclaimsBagsOnArrival.contains) ?? false)

        if crossesControl {
            steps.append(Step(name: "Passport control", icon: "person.text.rectangle",
                              minutes: bigAirport ? 25 : 15))
        }
        if reclaimsBags {
            steps.append(Step(name: "Baggage reclaim & customs", icon: "suitcase",
                              minutes: bigAirport ? 30 : 20))
        }

        // Screening again is its own question, not a free rider on the passport
        // desk. It happens when bags were reclaimed and must be re-dropped, when
        // flying to the US from abroad (those gates are screened separately),
        // or when a terminal change puts the passenger back through a
        // checkpoint. A Schengen-to-Schengen transfer meets none of the three.
        let usBound = countryCode(outbound.arrivalIATA).map { $0 == "US" } ?? false
        let leavingForUS = usBound && (countryCode(hub).map { $0 != "US" } ?? false)
        if reclaimsBags || leavingForUS || (differentTerminals && bigAirport) {
            // A real queue reading beats any tier — but only when it IS one.
            // The endpoint falls back to a time-of-day estimate away from the
            // airports it covers, and that deserves no special billing.
            let tier = bigAirport ? 15 : 10
            if context.securityIsLive, let live = context.securityMinutes {
                let age = context.securityAgeMinutes.map { "\($0)m ago" } ?? "just now"
                steps.append(Step(name: "Security recheck", icon: "figure.walk.motion",
                                  minutes: max(3, live), detail: "live queue · \(age)"))
            } else {
                steps.append(Step(name: "Security recheck", icon: "figure.walk.motion", minutes: tier))
            }
        }

        // Skipped when the walk was measured — that distance already ran gate
        // to gate, so charging a second walk would double-count it.
        if measuredWalk == nil {
            steps.append(Step(name: "Walk to gate", icon: "signpost.right", minutes: bigAirport ? 12 : 7))
        }
        // Long-haul closes its gate earlier than a short hop does.
        let longHaul = outbound.scheduledArrival.timeIntervalSince(outbound.scheduledDeparture) > 6 * 3600
        steps.append(Step(name: "At gate before boarding closes", icon: "door.left.hand.open",
                          minutes: longHaul ? 20 : 15))
        return steps
    }

    /// One sentence explaining an ABSENT passport check, shown only when the
    /// transfer changes country and still meets no border — precisely the case
    /// that otherwise looks like the app got it wrong.
    static func borderNote(inbound: Flight, outbound: Flight) -> String? {
        let areas = [inbound.departureIATA, inbound.arrivalIATA, outbound.arrivalIATA]
            .map(borderArea(of:))
        let known = areas.compactMap { $0 }
        guard known.count == 3, Set(known).count == 1, let area = known.first else { return nil }

        let countries = Set([inbound.departureIATA, inbound.arrivalIATA, outbound.arrivalIATA]
            .compactMap(countryCode))
        switch area {
        case .schengen where countries.count > 1:
            return "Both legs stay inside the Schengen area — no passport control on this transfer."
        case .commonTravelArea where countries.count > 1:
            return "Both legs stay inside the Common Travel Area — no passport control on this transfer."
        case .country where countries.count == 1:
            return "Domestic transfer — no passport control."
        default:
            return nil
        }
    }

    static func risk(neededMinutes: Int, layoverMinutes: Int) -> Risk {
        if layoverMinutes >= neededMinutes + 30 { return .relaxed }
        if layoverMinutes >= neededMinutes { return .normal }
        if layoverMinutes >= neededMinutes - 15 { return .tight }
        return .risky
    }
}

// MARK: - Colocated types
//
// `AirportConnectTimes` and `ConnectionInsights` would each be happier in their
// own file. They live here because Arc.xcodeproj carries an explicit source
// list rather than synchronized folders, so a new file has to be registered in
// project.pbxproj — and that file is being edited in parallel, where concurrent
// writes overwrite each other silently instead of conflicting. Worth splitting
// out in a quieter moment; nothing about the code depends on the arrangement.


/// Published minimum connecting times (MCT) for major hubs.
///
/// The MCT is the shortest connection an airport will sell on a single ticket.
/// It is the one number in this whole card that isn't Arc's estimate — it's the
/// airport's own floor, and it answers a question the step list can't: not "will
/// I make it" but "does anyone think this is a legal connection at all". A
/// layover under the published minimum is the one worth shouting about, because
/// a self-connected passenger who misses it is not rebooked for free.
///
/// HONEST SCOPE, and it matters. These are typical published figures. Real MCTs
/// vary by terminal PAIR (Charles de Gaulle is 60 minutes inside 2E and 90
/// across the airport), by airline, and by alliance, and they are revised.
/// Treat them as a sanity check to be corrected over time, never as a promise —
/// which is why the card says "typical published minimum" and never "official".
/// Anything absent from this table simply produces no cross-check, which is the
/// correct behaviour: silence beats a confident wrong number.
enum AirportConnectTimes {

    /// What kind of transfer the passenger is making, in the terms an MCT table
    /// is actually written in.
    enum Transfer {
        /// Both legs inside one country.
        case domestic
        /// Crosses a national border but stays in one control area — the
        /// Schengen-to-Schengen case, which needs no passport desk.
        case withinArea
        /// Enters or leaves a control area, so border formalities apply.
        case areaCrossing
    }

    struct Minimums {
        let domestic: Int
        let withinArea: Int
        let areaCrossing: Int

        func minutes(for transfer: Transfer) -> Int {
            switch transfer {
            case .domestic: domestic
            case .withinArea: withinArea
            case .areaCrossing: areaCrossing
            }
        }
    }

    /// Deliberately limited to hubs whose figures are widely published and
    /// stable. Adding an airport on a guess would defeat the purpose of having
    /// a cross-check at all.
    private static let table: [String: Minimums] = [
        // Europe
        "FRA": .init(domestic: 45, withinArea: 45, areaCrossing: 60),
        "MUC": .init(domestic: 30, withinArea: 35, areaCrossing: 45),
        "ZRH": .init(domestic: 40, withinArea: 40, areaCrossing: 40),
        "VIE": .init(domestic: 25, withinArea: 25, areaCrossing: 30),
        "AMS": .init(domestic: 40, withinArea: 40, areaCrossing: 50),
        "CDG": .init(domestic: 60, withinArea: 60, areaCrossing: 90),
        "LHR": .init(domestic: 60, withinArea: 60, areaCrossing: 75),
        "LGW": .init(domestic: 45, withinArea: 45, areaCrossing: 60),
        "DUB": .init(domestic: 45, withinArea: 45, areaCrossing: 60),
        "BRU": .init(domestic: 40, withinArea: 40, areaCrossing: 50),
        "CPH": .init(domestic: 30, withinArea: 35, areaCrossing: 45),
        "ARN": .init(domestic: 30, withinArea: 35, areaCrossing: 45),
        "OSL": .init(domestic: 30, withinArea: 35, areaCrossing: 45),
        "HEL": .init(domestic: 35, withinArea: 35, areaCrossing: 45),
        "MAD": .init(domestic: 45, withinArea: 45, areaCrossing: 60),
        "BCN": .init(domestic: 45, withinArea: 45, areaCrossing: 60),
        "LIS": .init(domestic: 45, withinArea: 50, areaCrossing: 60),
        "FCO": .init(domestic: 45, withinArea: 45, areaCrossing: 60),
        "MXP": .init(domestic: 45, withinArea: 45, areaCrossing: 60),
        "ATH": .init(domestic: 40, withinArea: 45, areaCrossing: 50),
        "IST": .init(domestic: 45, withinArea: 45, areaCrossing: 60),
        "WAW": .init(domestic: 35, withinArea: 35, areaCrossing: 45),
        "PRG": .init(domestic: 35, withinArea: 35, areaCrossing: 45),
        // North America — an international arrival clears immigration, bags and
        // customs before it flies on, which is why the crossing figure jumps.
        "ATL": .init(domestic: 40, withinArea: 40, areaCrossing: 90),
        "ORD": .init(domestic: 45, withinArea: 45, areaCrossing: 90),
        "JFK": .init(domestic: 60, withinArea: 60, areaCrossing: 90),
        "EWR": .init(domestic: 60, withinArea: 60, areaCrossing: 90),
        "LAX": .init(domestic: 50, withinArea: 50, areaCrossing: 90),
        "DFW": .init(domestic: 50, withinArea: 50, areaCrossing: 90),
        "SFO": .init(domestic: 45, withinArea: 45, areaCrossing: 90),
        "MIA": .init(domestic: 45, withinArea: 45, areaCrossing: 90),
        "BOS": .init(domestic: 45, withinArea: 45, areaCrossing: 90),
        "SEA": .init(domestic: 45, withinArea: 45, areaCrossing: 90),
        "DEN": .init(domestic: 45, withinArea: 45, areaCrossing: 90),
        "YYZ": .init(domestic: 50, withinArea: 50, areaCrossing: 90),
        "YVR": .init(domestic: 50, withinArea: 50, areaCrossing: 90),
        // Middle East / Asia-Pacific
        "DXB": .init(domestic: 60, withinArea: 60, areaCrossing: 60),
        "DOH": .init(domestic: 45, withinArea: 45, areaCrossing: 45),
        "SIN": .init(domestic: 60, withinArea: 60, areaCrossing: 60),
        "HKG": .init(domestic: 50, withinArea: 50, areaCrossing: 50),
        "ICN": .init(domestic: 45, withinArea: 45, areaCrossing: 45),
        "HND": .init(domestic: 60, withinArea: 60, areaCrossing: 60),
        "NRT": .init(domestic: 60, withinArea: 60, areaCrossing: 60),
        "BKK": .init(domestic: 60, withinArea: 60, areaCrossing: 60),
        "SYD": .init(domestic: 45, withinArea: 45, areaCrossing: 60),
    ]

    /// nil when this airport isn't in the table — the caller must then show no
    /// cross-check rather than invent one.
    static func publishedMinimum(at iata: String, transfer: Transfer) -> Int? {
        table[iata.uppercased()]?.minutes(for: transfer)
    }

    static func hasData(for iata: String) -> Bool {
        table[iata.uppercased()] != nil
    }
}


/// Gathers the things a connection can be MEASURED by, so the planner doesn't
/// have to guess them.
///
/// Everything here is best-effort and independently optional. A source that is
/// slow, unavailable, or simply has nothing for this airport contributes
/// nothing and the planner falls back to its tier for that one step — so the
/// card degrades a number at a time rather than failing.
enum ConnectionInsights {

    /// The observed gate history for a flight, per the Worker's `/gates/predict`.
    private struct GatePrediction: Codable {
        let gate: String?
        let terminal: String?
        let agreeing: Int
        let samples: Int
        let confidence: Double
    }

    /// Below this, the "usual gate" is noise rather than a pattern and is not
    /// worth putting a distance next to.
    private static let minimumGateConfidence = 0.5
    private static let minimumGateSamples = 3

    /// What the network side needs to know, as plain values.
    ///
    /// `Flight` is a SwiftData `@Model` and is not Sendable, so it cannot cross
    /// into the concurrent lookups below. Everything is read once here, on the
    /// actor that owns the object, and only these copies travel.
    private struct Snapshot: Sendable {
        let hub: String
        let hubLat: Double
        let hubLon: Double
        let inboundNumber: String
        let outboundNumber: String
        let assignedArrivalGate: String?
        let assignedDepartureGate: String?
    }

    @MainActor
    static func load(inbound: Flight, outbound: Flight) async -> ConnectionPlanner.Context {
        let hub = inbound.arrivalIATA.uppercased()
        guard let airport = ReferenceData.shared.airport(hub) else { return ConnectionPlanner.Context() }
        return await measure(Snapshot(
            hub: hub, hubLat: airport.lat, hubLon: airport.lon,
            inboundNumber: inbound.flightNumber, outboundNumber: outbound.flightNumber,
            assignedArrivalGate: inbound.arrivalGate,
            assignedDepartureGate: outbound.departureGate))
    }

    private static func measure(_ snapshot: Snapshot) async -> ConnectionPlanner.Context {
        var context = ConnectionPlanner.Context()
        let hub = snapshot.hub

        async let gatesTask = FlightAPIClient.shared.gates(iata: hub,
                                                           lat: snapshot.hubLat, lon: snapshot.hubLon)
        async let arrivalGuess = resolveGate(flight: snapshot.inboundNumber, at: hub,
                                             direction: "arr", assigned: snapshot.assignedArrivalGate)
        async let departureGuess = resolveGate(flight: snapshot.outboundNumber, at: hub,
                                               direction: "dep", assigned: snapshot.assignedDepartureGate)
        async let securityTask = security(at: hub)

        let (gates, from, to, queue) = await (gatesTask, arrivalGuess, departureGuess, securityTask)

        if let from, let to,
           let a = FlightAPIClient.matchGate(gates, to: from.ref),
           let b = FlightAPIClient.matchGate(gates, to: to.ref) {
            context.fromGate = a.ref
            context.toGate = b.ref
            context.gatesPredicted = from.predicted || to.predicted
            context.gateDistanceMeters = GeoMath.distanceKm(
                CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon),
                CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon)) * 1000
        }

        if let queue {
            context.securityMinutes = queue.minutes
            context.securityIsLive = queue.isLive
            context.securityAgeMinutes = queue.ageMinutes
        }
        return context
    }

    // MARK: - Gates

    private struct ResolvedGate { let ref: String; let predicted: Bool }

    /// The gate this leg will use: the assigned one when the airline has named
    /// it, otherwise the one this flight number keeps using, per the tracker's
    /// own observations. The distinction is carried forward, because a habit is
    /// not an assignment and the card must not present it as one.
    private static func resolveGate(flight: String, at hub: String,
                                    direction: String, assigned: String?) async -> ResolvedGate? {
        if let assigned, !assigned.trimmingCharacters(in: .whitespaces).isEmpty {
            return ResolvedGate(ref: assigned, predicted: false)
        }
        guard let prediction = await predictedGate(flight: flight,
                                                   airport: hub, direction: direction),
              let gate = prediction.gate,
              prediction.samples >= minimumGateSamples,
              prediction.confidence >= minimumGateConfidence else { return nil }
        return ResolvedGate(ref: gate, predicted: true)
    }

    private static func predictedGate(flight: String, airport: String,
                                      direction: String) async -> GatePrediction? {
        let base = UserDefaults.standard.string(forKey: "apiEndpoint")
            ?? "https://arc-backend.owncalai.workers.dev"
        guard var components = URLComponents(string: base + "/gates/predict") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "flight", value: flight),
            URLQueryItem(name: direction, value: airport),
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(GatePrediction.self, from: data)
    }

    // MARK: - Security

    private struct Queue { let minutes: Int; let isLive: Bool; let ageMinutes: Int? }

    private static func security(at iata: String) async -> Queue? {
        guard let info = try? await FlightAPIClient.shared.securityWaitTime(iata: iata),
              let minutes = info.securityMinutes else { return nil }
        // The endpoint answers with a time-of-day estimate wherever it has no
        // real feed. That is no better than our own tier, so it is not dressed
        // up as a measurement.
        let measuredAt = info.updatedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        let age = measuredAt.map { max(0, Int(Date.now.timeIntervalSince($0) / 60)) }
        // A reading nobody has refreshed in half an hour is history, not a
        // queue — fall back to the tier rather than call it live.
        guard info.source != "waitport" || (age ?? 0) <= 30 else {
            return Queue(minutes: minutes, isLive: false, ageMinutes: nil)
        }
        return Queue(minutes: minutes, isLive: info.source == "waitport", ageMinutes: age)
    }
}
