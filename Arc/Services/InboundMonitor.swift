import Foundation
import CoreLocation

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
        let todayStr = DateHelpers.apiDate(flight.scheduledDeparture, at: flight.departureIATA)
        let yesterdayStr = DateHelpers.apiDate(flight.scheduledDeparture.addingTimeInterval(-86400), at: flight.departureIATA)

        let todayLegs = (try? await FlightAPIClient.shared.inboundLegs(registration: registration, date: todayStr)) ?? []
        let yesterdayLegs = (try? await FlightAPIClient.shared.inboundLegs(registration: registration, date: yesterdayStr)) ?? []
        let legs = todayLegs + yesterdayLegs

        // Two network awaits sit above — the flight can be deleted meanwhile.
        guard !flight.isDeleted, flight.modelContext != nil else { return }
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

        // When the immediate inbound is already in the air, ask ADS-B where it
        // actually is: remaining distance at current speed (+ a fixed
        // approach/taxi buffer) beats any schedule projection, in both
        // directions — it catches planes making up time AND planes holding.
        var liveETA: Date?
        if inbound.actualArrival == nil, inbound.status != "landed",
           inbound.scheduledDeparture.map({ $0 <= .now }) == true,
           let dest = ReferenceData.shared.airport(flight.departureIATA),
           let pos = try? await FlightAPIClient.shared.livePosition(
               icao24: flight.aircraftICAO24, registration: registration),
           !pos.on_ground, pos.velocity > 50 {
            let remainingKm = GeoMath.distanceKm(
                .init(latitude: pos.lat, longitude: pos.lon), dest.coordinate)
            liveETA = Date.now.addingTimeInterval(remainingKm * 1000 / pos.velocity + 15 * 60)
        }

        // Legacy single-inbound fields — still what the detail card and
        // late-inbound notification read. Lateness is ARRIVAL lateness (how
        // late the plane reaches us), not the raw departure delay the API
        // reports — a 40m-late push-back that lands 15m late should say 15.
        flight.inboundFlightNumber = inbound.flightNumber
        flight.inboundRoute = "\(inbound.depIATA) → \(inbound.arrIATA)"
        if let sched = inbound.scheduledArrival,
           let eff = liveETA ?? inbound.effectiveArrival {
            flight.inboundDelayMinutes = max(0, Int(eff.timeIntervalSince(sched) / 60))
        } else {
            flight.inboundDelayMinutes = inbound.delayMinutes
        }
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
               officialDelayMinutes: flight.delayMinutes,
               liveInboundETA: liveETA) {
            flight.predictedDelayMinutes = p.minutes
            flight.predictionReason = p.reason
            // The moment Arc first says it, filed so the gap to the airline's
            // own admission can be measured rather than asserted. Only the
            // first one counts — the Worker ignores duplicates, so a re-poll
            // of the same prediction cannot reset the clock — but sending it
            // only on the transition keeps the traffic honest too.
            if previous == 0, let uid = ArcSupabase.shared.currentUser?.id {
                let number = flight.flightNumber, dep = flight.scheduledDeparture
                let minutes = p.minutes, official = flight.delayMinutes, reason = p.reason
                Task {
                    await FlightAPIClient.shared.recordDelayPrediction(
                        flightNumber: number, scheduledDeparture: dep,
                        predictedMinutes: minutes, officialMinutes: official,
                        reason: reason, userId: uid)
                }
            }
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
