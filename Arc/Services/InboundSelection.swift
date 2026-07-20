import Foundation

/// Pure selection logic for "Where's My Plane": given a tail's flight history,
/// which leg is genuinely the one feeding into this flight? Kept separate from
/// `InboundMonitor` (which does the networking) so it's unit-testable without
/// a live API call.
enum InboundSelection {
    /// The most recent leg, among `legs`, that lands at `departureIATA` no
    /// later than `beforeDeparture` — i.e. the immediately-prior rotation of
    /// this same tail, which is what actually determines this flight's gate
    /// departure time if it's running late.
    static func selectInboundLeg(
        from legs: [FlightAPIClient.FlightSearchResult],
        excludingFlightNumber currentNumber: String,
        arrivingAt departureIATA: String,
        before beforeDeparture: Date
    ) -> FlightAPIClient.FlightSearchResult? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        let candidates = legs.filter { leg in
            guard leg.flight_number != currentNumber,
                  leg.arr_iata.uppercased() == departureIATA.uppercased(),
                  let arrival = iso.date(from: leg.arr_scheduled)
            else { return false }
            return arrival <= beforeDeparture
        }

        return candidates.max { a, b in
            let da = iso.date(from: a.arr_scheduled) ?? .distantPast
            let db = iso.date(from: b.arr_scheduled) ?? .distantPast
            return da < db
        }
    }
}
