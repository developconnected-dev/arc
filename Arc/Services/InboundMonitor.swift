import Foundation

/// Monitors the inbound aircraft for a flight — the previous rotation of the
/// same tail — via the Worker's `/inbound` endpoint (AeroDataBox tail-number
/// history). Populates `Flight.inbound*` with the real previous leg instead of
/// guessing from this flight's own status.
enum InboundMonitor {

    @MainActor
    static func checkInbound(for flight: Flight) async {
        guard let registration = flight.aircraftRegistration, !registration.isEmpty else { return }

        // The inbound leg may have departed the day before (overnight rotation),
        // so pull both the flight's own date and the previous day, then merge.
        // Each call degrades to `[]` independently rather than failing the whole check.
        let todayStr = flight.scheduledDeparture.formatted(.iso8601.year().month().day())
        let yesterdayStr = flight.scheduledDeparture.addingTimeInterval(-86400).formatted(.iso8601.year().month().day())

        let todayLegs = (try? await FlightAPIClient.shared.inboundLegs(registration: registration, date: todayStr)) ?? []
        let yesterdayLegs = (try? await FlightAPIClient.shared.inboundLegs(registration: registration, date: yesterdayStr)) ?? []
        let legs = todayLegs + yesterdayLegs

        flight.inboundChecked = true

        guard let inbound = InboundSelection.selectInboundLeg(
            from: legs,
            excludingFlightNumber: flight.flightNumber,
            arrivingAt: flight.departureIATA,
            before: flight.scheduledDeparture
        ) else { return }

        flight.inboundFlightNumber = inbound.flight_number
        flight.inboundRoute = "\(inbound.dep_iata) → \(inbound.arr_iata)"
        flight.inboundDelayMinutes = inbound.delay ?? 0
        flight.inboundArrivalTime = DateHelpers.parseAPIDate(inbound.arr_scheduled)
    }
}
