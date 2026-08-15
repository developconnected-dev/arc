import Foundation

/// The journey inside a trip invite — what crosses from the sender's phone to
/// the recipient's, and what becomes the recipient's own `Flight` on Accept.
///
/// Same snake_case keys as `user_flights`, deliberately: this is that mirror
/// with the private fields removed. Booking code, seat and notes identify the
/// sender's booking, not the journey, so they never leave the sender's device;
/// the recipient adds their own. Everything is optional so a snapshot written by
/// a newer build still decodes on an older one.
struct TripInvitePayload: Codable, Equatable {
    var mode: String?
    var data_tier: String?
    var flight_number: String?
    var marketing_number: String?
    var airline: String?
    var airline_icao: String?
    var departure_iata: String?
    var arrival_iata: String?
    var departure_stop_id: String?
    var arrival_stop_id: String?
    var departure_tz: String?
    var arrival_tz: String?
    var departure_city: String?
    var arrival_city: String?
    var departure_lat: Double?
    var departure_lon: Double?
    var arrival_lat: Double?
    var arrival_lon: Double?
    var scheduled_departure: String?
    var scheduled_arrival: String?
    var estimated_arrival: String?
    var status: String?
    var delay_minutes: Int?
    var departure_gate: String?
    var departure_terminal: String?
    var arrival_gate: String?
    var arrival_terminal: String?
    var baggage_claim: String?
    var aircraft_type: String?
    var aircraft_registration: String?
    var aircraft_icao24: String?
    var vessel_name: String?
    var vessel_mmsi: String?
    var operator_logo_url: String?
    var disruption_note: String?
    var booking_url: String?
    var rail_trip_id: String?
    var awaiting_schedule: Bool?
    /// The routed track for a train — [[lat, lon], …] — so the recipient's map
    /// draws the real line too instead of an arc across the countryside.
    var route_path: [[Double]]?

    /// The upload body. A dictionary rather than an encoded `Self` because the
    /// rest of the client speaks `[String: Any]` to PostgREST, and because
    /// building it by hand is where the private fields are visibly left out.
    static func body(for flight: Flight) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        func str(_ d: Date?) -> Any { d.map { iso.string(from: $0) } ?? NSNull() }
        var body: [String: Any] = [
            "mode": flight.modeRaw,
            "data_tier": flight.dataTierRaw,
            "flight_number": flight.flightNumber,
            "marketing_number": flight.marketingFlightNumber as Any,
            "airline": flight.airline,
            "airline_icao": flight.airlineICAO,
            "departure_iata": flight.departureIATA,
            "arrival_iata": flight.arrivalIATA,
            "departure_stop_id": flight.departureStopID as Any,
            "arrival_stop_id": flight.arrivalStopID as Any,
            "departure_tz": flight.departureTZID as Any,
            "arrival_tz": flight.arrivalTZID as Any,
            "departure_city": flight.departureCity,
            "arrival_city": flight.arrivalCity,
            "departure_lat": flight.departureLat,
            "departure_lon": flight.departureLon,
            "arrival_lat": flight.arrivalLat,
            "arrival_lon": flight.arrivalLon,
            "scheduled_departure": iso.string(from: flight.scheduledDeparture),
            "scheduled_arrival": iso.string(from: flight.scheduledArrival),
            "estimated_arrival": str(flight.estimatedArrival),
            "status": flight.statusRaw,
            "delay_minutes": flight.delayMinutes,
            "departure_gate": flight.departureGate as Any,
            "departure_terminal": flight.departureTerminal as Any,
            "arrival_gate": flight.arrivalGate as Any,
            "arrival_terminal": flight.arrivalTerminal as Any,
            "baggage_claim": flight.baggageClaim as Any,
            "aircraft_type": flight.aircraftType as Any,
            "aircraft_registration": flight.aircraftRegistration as Any,
            "aircraft_icao24": flight.aircraftICAO24 as Any,
            "vessel_name": flight.vesselName as Any,
            "vessel_mmsi": flight.vesselMMSI as Any,
            "operator_logo_url": flight.operatorLogoURL as Any,
            "disruption_note": flight.disruptionNote as Any,
            "booking_url": flight.bookingURL as Any,
            "rail_trip_id": flight.railTripID as Any,
            "awaiting_schedule": flight.awaitingSchedule,
        ]
        let path = flight.routePath
        if path.count >= 3 { body["route_path"] = path.map { [$0.lat, $0.lon] } }
        return body
    }

    /// The recipient's own copy. A fresh id, fresh `addedAt`, no seat, no
    /// booking code, default audience — from here on it is their trip, tracked
    /// and refreshed by their device exactly like one they searched for.
    func materialize() -> Flight {
        let departure = DateHelpers.parseAPIDate(scheduled_departure) ?? .now
        let arrival = DateHelpers.parseAPIDate(scheduled_arrival) ?? departure.addingTimeInterval(2 * 3600)
        let f = Flight(flightNumber: flight_number ?? "", date: departure)
        f.mode = TripMode(rawValue: mode ?? "air") ?? .air
        f.dataTier = DataTier(rawValue: data_tier ?? "live") ?? .live
        f.marketingFlightNumber = marketing_number
        f.airline = airline ?? ""
        f.airlineICAO = airline_icao ?? ""
        f.departureIATA = departure_iata ?? ""
        f.arrivalIATA = arrival_iata ?? ""
        f.departureStopID = departure_stop_id
        f.arrivalStopID = arrival_stop_id
        f.departureTZID = departure_tz
        f.arrivalTZID = arrival_tz
        f.departureCity = departure_city ?? ""
        f.arrivalCity = arrival_city ?? ""
        f.departureLat = departure_lat ?? 0
        f.departureLon = departure_lon ?? 0
        f.arrivalLat = arrival_lat ?? 0
        f.arrivalLon = arrival_lon ?? 0
        f.scheduledDeparture = departure
        f.scheduledArrival = arrival
        f.estimatedArrival = DateHelpers.parseAPIDate(estimated_arrival)
        f.statusRaw = FlightStatus.heal(rawValue: status ?? "scheduled", scheduledArrival: arrival).rawValue
        f.delayMinutes = delay_minutes ?? 0
        f.departureGate = departure_gate
        f.departureTerminal = departure_terminal
        f.arrivalGate = arrival_gate
        f.arrivalTerminal = arrival_terminal
        f.baggageClaim = baggage_claim
        f.aircraftType = aircraft_type
        f.aircraftRegistration = aircraft_registration
        f.aircraftICAO24 = aircraft_icao24
        f.vesselName = vessel_name
        f.vesselMMSI = vessel_mmsi
        f.operatorLogoURL = operator_logo_url
        f.disruptionNote = disruption_note
        f.bookingURL = booking_url
        f.railTripID = rail_trip_id
        f.awaitingSchedule = awaiting_schedule ?? false
        if let route_path, route_path.count >= 3 {
            f.routePathData = try? JSONEncoder().encode(route_path)
        }
        return f
    }

    /// Round-trips the upload dictionary through JSON — the exact bytes
    /// PostgREST stores and hands back — into the typed payload.
    static func decode(_ body: [String: Any]) throws -> TripInvitePayload {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try JSONDecoder().decode(TripInvitePayload.self, from: data)
    }
}

/// Which friends should ALSO see a trip, given who's on it. Being invited
/// implies being able to see the sender's copy: `nil` (everyone) already does;
/// an explicit list gains the companions; a private trip stays private to
/// exactly the people on it.
enum TripCompanions {
    static func audience(sharedWithIds: [String]?, travellingWithIds: [String]) -> [String]? {
        guard let sharedWithIds else { return nil }
        var out = sharedWithIds
        for id in travellingWithIds where !out.contains(id) { out.append(id) }
        return out
    }
}
