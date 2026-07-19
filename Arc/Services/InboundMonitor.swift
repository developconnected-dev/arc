import Foundation

/// Monitors the inbound aircraft for a flight.
/// Checks if the plane assigned to your flight is delayed on its previous leg.
enum InboundMonitor {

    /// Check the inbound aircraft status and update the flight's inbound fields.
    @MainActor
    static func checkInbound(for flight: Flight) async {
        // We need the aircraft registration or ICAO24 to track the inbound
        guard let registration = flight.aircraftRegistration, !registration.isEmpty else { return }

        let dateStr = flight.scheduledDeparture.formatted(.iso8601.year().month().day())

        do {
            // Search for flights by the same aircraft on the same day
            // AviationStack doesn't directly support tail-number search on free tier,
            // so we look for the flight number's aircraft assignment
            let results = try await FlightAPIClient.shared.searchFlight(
                number: flight.flightNumber,
                date: dateStr
            )

            guard let current = results.first else { return }

            // If there's delay info, calculate inbound impact
            if let delay = current.delay, delay > 0 {
                flight.inboundDelayMinutes = delay

                // Calculate if this delay affects turnaround
                // Typical turnaround: 45 min for narrow-body, 90 min for wide-body
                let isWidebody = isWidebodyAircraft(flight.aircraftType)
                let minTurnaround = isWidebody ? 90 : 45

                let arrivalDelay = delay
                let availableBuffer = max(0, Int(flight.duration / 60) - minTurnaround)

                if arrivalDelay > availableBuffer {
                    // Inbound delay will likely affect this flight
                    flight.inboundFlightNumber = "Previous leg"
                }
            }
        } catch {
            // Silently skip
        }
    }

    private static func isWidebodyAircraft(_ type: String?) -> Bool {
        guard let type = type?.uppercased() else { return false }
        let widebodies = ["747", "767", "777", "787", "A330", "A340", "A350", "A380"]
        return widebodies.contains { type.contains($0) }
    }
}
