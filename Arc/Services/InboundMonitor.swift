import Foundation

/// Monitors the inbound aircraft for a flight — the tail's whole day of legs
/// leading up to it — via the Worker's `/inbound` endpoint (AeroDataBox
/// tail-number history). Populates the rotation chain, the legacy
/// `Flight.inbound*` fields (immediate inbound), and Arc's knock-on delay
/// prediction with a notification when it materially worsens.
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

        let chain = RotationChain.buildChain(
            from: legs,
            endingAt: flight.departureIATA,
            before: flight.scheduledDeparture,
            excludingFlightNumber: flight.flightNumber)
        flight.rotationLegs = chain

        guard let inbound = chain.last else {
            flight.predictedDelayMinutes = 0
            flight.predictionReason = nil
            return
        }

        // Legacy single-inbound fields — still what the detail card and
        // late-inbound notification read.
        flight.inboundFlightNumber = inbound.flightNumber
        flight.inboundRoute = "\(inbound.depIATA) → \(inbound.arrIATA)"
        flight.inboundDelayMinutes = inbound.delayMinutes
        flight.inboundArrivalTime = inbound.scheduledArrival

        // The best pre-departure news travels as a push, once, and only when
        // it's close enough to departure to be reassuring rather than noise.
        let hoursOut = flight.scheduledDeparture.timeIntervalSince(.now) / 3600
        if !flight.inboundArrivedNotified, hoursOut > 0, hoursOut <= 4,
           inbound.status == "landed" || (inbound.effectiveArrival.map { $0 <= .now } ?? false) {
            flight.inboundArrivedNotified = true
            ArcNotifications.notifyInboundArrived(flight: flight)
        }

        // Knock-on prediction: can the plane physically make our departure?
        // Whole-chain math, so lateness two airports away is seen hours
        // before the immediate inbound admits anything.
        let previous = flight.predictedDelayMinutes
        if let p = RotationChain.predictChainDelay(
               chain: chain,
               scheduledDeparture: flight.scheduledDeparture,
               aircraftType: flight.aircraftType,
               officialDelayMinutes: flight.delayMinutes) {
            flight.predictedDelayMinutes = p.minutes
            flight.predictionReason = p.reason
            // Notify only when the picture worsens meaningfully — not on
            // every re-poll of the same prediction.
            if p.minutes >= previous + 10 {
                ArcNotifications.notifyPredictedDelay(flight: flight, minutes: p.minutes)
            }
        } else {
            flight.predictedDelayMinutes = 0
            flight.predictionReason = nil
        }
    }
}
