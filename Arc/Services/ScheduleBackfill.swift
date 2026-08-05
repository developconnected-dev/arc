import Foundation

/// Keeps the promise made when a flight is added by hand.
///
/// Airlines file schedules in batches, and a real booking months out often
/// isn't in any data feed yet — searching for it returns nothing even though
/// other flights the same day resolve fine. Rather than leaving the user with
/// whatever they typed forever, every hand-entered future flight is looked up
/// once a day until the schedule appears, then filled in.
///
/// This is deliberately outside `FlightTracker`'s polling tiers: those skip
/// anything more than 24h out, which is precisely the window this exists for.
@MainActor
enum ScheduleBackfill {
    /// Once a day. Airlines publish in batches rather than continuously, so a
    /// tighter cadence would just spend quota to learn the same "not yet".
    nonisolated static let interval: TimeInterval = 24 * 3600

    nonisolated static func isDue(_ flight: Flight, at now: Date) -> Bool {
        guard flight.awaitingSchedule else { return false }
        // Once it has departed there's nothing left to pre-fill; the normal
        // tracker owns it from there.
        guard flight.scheduledDeparture > now else { return false }
        guard let last = flight.lastScheduleCheckAt else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    /// A flight number can fly several legs in a day, so prefer the ones whose
    /// route matches what the user typed — and among those, the leg scheduled
    /// CLOSEST to this flight's departure. Shuttle numbers fly one route
    /// multiple times a day; route-only matching stamped the morning leg's
    /// actual times onto an evening flight, which then read "6h early".
    nonisolated static func bestLeg(_ legs: [FlightAPIClient.FlightSearchResult],
                                    matching flight: Flight) -> FlightAPIClient.FlightSearchResult? {
        let dep = flight.departureIATA.uppercased()
        let arr = flight.arrivalIATA.uppercased()
        let scheduled = flight.scheduledDeparture
        let onRoute = legs.filter {
            $0.dep_iata.uppercased() == dep && $0.arr_iata.uppercased() == arr
        }
        let pool = onRoute.isEmpty ? legs : onRoute
        func distance(_ leg: FlightAPIClient.FlightSearchResult) -> TimeInterval {
            guard let d = DateHelpers.parseAPIDate(leg.dep_scheduled) else { return .greatestFiniteMagnitude }
            return abs(d.timeIntervalSince(scheduled))
        }
        return pool.min { distance($0) < distance($1) }
    }

    /// The published schedule wins over what was typed — that's the whole
    /// point — but anything the user owns (seat, booking code, notes, who it's
    /// shared with) is theirs and is never touched here.
    static func apply(_ leg: FlightAPIClient.FlightSearchResult, to flight: Flight) {
        if let dep = DateHelpers.parseAPIDate(leg.dep_scheduled) { flight.scheduledDeparture = dep }
        if let arr = DateHelpers.parseAPIDate(leg.arr_scheduled) { flight.scheduledArrival = arr }
        if let marketing = leg.marketing_number, !marketing.isEmpty {
            flight.marketingFlightNumber = marketing
        }
        if !leg.airline_name.isEmpty { flight.airline = leg.airline_name }
        if !leg.dep_iata.isEmpty { flight.departureIATA = leg.dep_iata }
        if !leg.arr_iata.isEmpty { flight.arrivalIATA = leg.arr_iata }
        if let city = leg.dep_city, !city.isEmpty { flight.departureCity = city }
        if let city = leg.arr_city, !city.isEmpty { flight.arrivalCity = city }
        if let lat = leg.dep_lat, let lon = leg.dep_lon { flight.departureLat = lat; flight.departureLon = lon }
        if let lat = leg.arr_lat, let lon = leg.arr_lon { flight.arrivalLat = lat; flight.arrivalLon = lon }
        if let type = leg.aircraft_type, !type.isEmpty { flight.aircraftType = type }
        if let reg = leg.aircraft_registration, !reg.isEmpty { flight.aircraftRegistration = reg }
        if let icao24 = leg.aircraft_icao24, !icao24.isEmpty { flight.aircraftICAO24 = icao24 }
        if let gate = leg.dep_gate, !gate.isEmpty { flight.departureGate = gate }
        if let terminal = leg.dep_terminal, !terminal.isEmpty { flight.departureTerminal = terminal }
        flight.delayMinutes = leg.delay ?? 0
        flight.awaitingSchedule = false
    }

    /// One lookup. The timestamp is written whether or not anything was found,
    /// so a flight that stays unpublished is tried once a day rather than on
    /// every pass of the tracker loop.
    static func check(_ flight: Flight, at now: Date = .now) async {
        flight.lastScheduleCheckAt = now
        let date = DateHelpers.apiDate(flight.scheduledDeparture, at: flight.departureIATA)
        guard let legs = try? await FlightAPIClient.shared.searchFlight(
            number: flight.flightNumber, date: date),
              let leg = bestLeg(legs, matching: flight) else { return }

        // The typed departure keys two things that must move WITH it: the
        // 2-hour reminder (else it fires 2 h before a time that no longer
        // exists) and the shared row's natural key (else friends keep a
        // frozen duplicate at the old time forever).
        let typedDeparture = flight.scheduledDeparture
        apply(leg, to: flight)
        if flight.scheduledDeparture != typedDeparture {
            ArcNotifications.removeDepartureReminder(flightNumber: flight.flightNumber, scheduledDeparture: typedDeparture)
            ArcNotifications.scheduleDepartureReminder(for: flight)
            let number = flight.flightNumber
            Task { try? await ArcSupabase.shared.unshareFlight(flightNumber: number, scheduledDeparture: typedDeparture) }
        }
        ArcNotifications.scheduleFound(flight)
        // Push the real times to friends now rather than waiting for this
        // flight to enter a polling tier, which could be weeks away.
        // The widget is refreshed by the tracker's own sync pass.
        Task { try? await ArcSupabase.shared.shareFlight(flight) }
    }
}
