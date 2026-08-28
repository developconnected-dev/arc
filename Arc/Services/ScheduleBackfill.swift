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
        // Only an airline files a schedule this can wait for. A hand-added train
        // or sailing would be looked up in the airline feed once a day forever,
        // and the answer would always be no — its provider needs the boarding
        // stop and a service key, which is a different mechanism entirely.
        guard flight.mode.hasAirlineSchedule else { return false }
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
    /// `allowRouteChange` gates the off-route fallback. The backfill may take
    /// it (a hand-typed flight can carry a mis-picked airport, and the
    /// airline's filing corrects it — but only within a day of the typed
    /// time). Live tracking must NOT: an off-route pick there stamps a
    /// different leg's status, gates and actual times onto the tracked
    /// flight, and rewrites its route mid-trip.
    nonisolated static func bestLeg(_ legs: [FlightAPIClient.FlightSearchResult],
                                    matching flight: Flight,
                                    allowRouteChange: Bool = false) -> FlightAPIClient.FlightSearchResult? {
        let dep = flight.departureIATA.uppercased()
        let arr = flight.arrivalIATA.uppercased()
        let scheduled = flight.scheduledDeparture
        let onRoute = legs.filter {
            $0.dep_iata.uppercased() == dep && $0.arr_iata.uppercased() == arr
        }
        func distance(_ leg: FlightAPIClient.FlightSearchResult) -> TimeInterval {
            guard let d = DateHelpers.parseAPIDate(leg.dep_scheduled) else { return .greatestFiniteMagnitude }
            return abs(d.timeIntervalSince(scheduled))
        }
        if let best = onRoute.min(by: { distance($0) < distance($1) }) {
            return preferOperating(best, among: onRoute)
        }
        guard allowRouteChange else { return nil }
        guard let fallback = legs.min(by: { distance($0) < distance($1) }),
              distance(fallback) <= 24 * 3600 else { return nil }
        return fallback
    }

    /// A reschedule is sometimes filed as TWO rows: the original operation
    /// cancelled (or wearing the provider's "likely cancelled" guess), its
    /// replacement a separate leg minutes to a couple of hours away on the
    /// same route. Closest-by-time alone picks the cancelled one — the
    /// stored time IS the original's — and the app then asserts a
    /// cancellation for a flight that operates. Within this window two
    /// same-number departures on one route cannot be two operations (no
    /// turnaround is that fast), so the living sibling IS the flight,
    /// moved; beyond it — a shuttle's other rotation, hours away — the
    /// cancellation is real and stays loud. Mirrors the Worker's pickLeg.
    nonisolated static let rescheduleWindow: TimeInterval = 3 * 3600

    private nonisolated static func disfavored(_ leg: FlightAPIClient.FlightSearchResult) -> Bool {
        leg.status == "cancelled" || leg.cancel_uncertain == true
    }

    nonisolated static func preferOperating(
        _ best: FlightAPIClient.FlightSearchResult,
        among candidates: [FlightAPIClient.FlightSearchResult]
    ) -> FlightAPIClient.FlightSearchResult {
        guard disfavored(best),
              let bestDep = DateHelpers.parseAPIDate(best.dep_scheduled) else { return best }
        let replacement = candidates
            .filter { !disfavored($0) }
            .compactMap { leg -> (FlightAPIClient.FlightSearchResult, TimeInterval)? in
                guard let d = DateHelpers.parseAPIDate(leg.dep_scheduled) else { return nil }
                let gap = abs(d.timeIntervalSince(bestDep))
                return gap <= rescheduleWindow ? (leg, gap) : nil
            }
            .min { $0.1 < $1.1 }?.0
        return replacement ?? best
    }

    /// The delay a stored flight should display, measured against ITS OWN
    /// schedule rather than the leg's. Identical schedules hand the leg's
    /// delay back unchanged; a retimed leg — or the re-filing
    /// `preferOperating` swapped in for a cancelled row — carries its shift
    /// as lateness, so every surface rendering scheduled-time-plus-delay
    /// lands on the real departure. Never negative: a flight moved earlier
    /// renders at the stored time, the safe direction to be wrong in.
    /// Mirrors the Worker's effectiveDelayMinutes.
    nonisolated static func effectiveDelayMinutes(
        of leg: FlightAPIClient.FlightSearchResult, against stored: Date
    ) -> Int {
        let raw = max(0, leg.delay ?? 0)
        guard let legSched = DateHelpers.parseAPIDate(leg.dep_scheduled) else { return raw }
        return max(0, Int((legSched.timeIntervalSince(stored) / 60 + Double(raw)).rounded()))
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
        // A found schedule means a provider is now reporting this leg — the
        // manual tier (and its "Added by you" qualifier) no longer applies.
        if let tier = leg.data_tier, let parsed = DataTier(rawValue: tier) {
            flight.dataTier = parsed
        } else {
            flight.dataTier = .live
        }
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
              let leg = bestLeg(legs, matching: flight, allowRouteChange: true) else { return }
        // The lookup awaited the network — the flight may be gone by now.
        guard !flight.isDeleted, flight.modelContext != nil else { return }

        // An inferred timetable (the Worker shifting a neighbouring day over a
        // provider hole) is worth taking when the flight has only typed times,
        // but it is not the airline's filing: keep looking, and don't announce
        // "schedule confirmed" for it.
        let isRealRecord = (leg.data_tier ?? "live") == "live"
        if !isRealRecord && flight.dataTier != .manual { return }

        // The typed departure keys two things that must move WITH it: the
        // 2-hour reminder (else it fires 2 h before a time that no longer
        // exists) and the shared row's natural key (else friends keep a
        // frozen duplicate at the old time forever).
        let typedDeparture = flight.scheduledDeparture
        // Companions were invited under the TYPED departure — the invite's
        // natural key. Capture who's still waiting before the time moves, so
        // the invitation can follow the schedule instead of orphaning.
        let pendingInviteeIds = FriendsStore.shared.pendingCompanions(for: flight).map(\.id)
        apply(leg, to: flight)
        if flight.scheduledDeparture != typedDeparture {
            ArcNotifications.removeDepartureReminder(flightNumber: flight.flightNumber, scheduledDeparture: typedDeparture)
            ArcNotifications.scheduleDepartureReminder(for: flight)
            let number = flight.flightNumber
            let moved = flight
            Task {
                try? await ArcSupabase.shared.unshareFlight(flightNumber: number, scheduledDeparture: typedDeparture)
                // Open invites keyed on the old time would let a friend Accept
                // a journey at a time that no longer exists.
                try? await ArcSupabase.shared.withdrawTripInvites(flightNumber: number, scheduledDeparture: typedDeparture)
                if !pendingInviteeIds.isEmpty, !moved.isDeleted {
                    try? await ArcSupabase.shared.sendTripInvites(moved, to: pendingInviteeIds)
                    await FriendsStore.shared.refreshSentTripInvites()
                }
            }
        }
        if isRealRecord {
            ArcNotifications.scheduleFound(flight)
        } else {
            flight.awaitingSchedule = true   // a timetable filled the gap; the filing is still awaited
        }
        // Push the real times to friends now rather than waiting for this
        // flight to enter a polling tier, which could be weeks away.
        // The widget is refreshed by the tracker's own sync pass.
        Task { try? await ArcSupabase.shared.shareFlight(flight) }
    }
}
