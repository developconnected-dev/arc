import Foundation

/// Connection Assistant — pure, unit-testable logic. Detects connections
/// between the user's flights, breaks the transfer into concrete steps with
/// typical times, and rates the risk live as delays move the layover around.
///
/// Honest scope: step times are tiered heuristics (airport size, international
/// vs domestic), not a per-airport procedure database — the risk tiers are
/// calibrated to be conservative rather than precise.
enum ConnectionPlanner {

    struct Step: Equatable {
        let name: String
        let icon: String
        let minutes: Int
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

    static func plan(inbound: Flight, outbound: Flight) -> Plan {
        let steps = transferSteps(inbound: inbound, outbound: outbound)
        let needed = steps.reduce(0) { $0 + $1.minutes }
        let layover = Int(outbound.effectiveDeparture.timeIntervalSince(inbound.effectiveArrival) / 60)
        return Plan(inbound: inbound, outbound: outbound,
                    steps: steps, neededMinutes: needed,
                    layoverMinutes: layover,
                    risk: risk(neededMinutes: needed, layoverMinutes: layover))
    }

    /// The step list a passenger actually walks through, in order.
    static func transferSteps(inbound: Flight, outbound: Flight) -> [Step] {
        var steps: [Step] = []

        let widebody = ["747", "777", "787", "A330", "A340", "A350", "A380", "767"]
            .contains { (inbound.aircraftType ?? "").uppercased().contains($0) }
        steps.append(Step(name: "Deplane", icon: "figure.walk.departure", minutes: widebody ? 18 : 12))

        let hubIATAs: Set<String> = ["FRA", "CDG", "AMS", "LHR", "IST", "MUC", "MAD", "BCN",
                                     "FCO", "JFK", "EWR", "ORD", "ATL", "DFW", "LAX", "DXB",
                                     "DOH", "SIN", "HND", "ICN", "PEK", "PVG"]
        let bigAirport = hubIATAs.contains(inbound.arrivalIATA.uppercased())

        let differentTerminals = inbound.arrivalTerminal != nil
            && outbound.departureTerminal != nil
            && inbound.arrivalTerminal != outbound.departureTerminal
        if differentTerminals {
            steps.append(Step(name: "Terminal change", icon: "bus", minutes: bigAirport ? 20 : 12))
        } else {
            steps.append(Step(name: "Transfer walk", icon: "figure.walk", minutes: bigAirport ? 14 : 8))
        }

        // Country change across the connection ⇒ passport control somewhere in
        // the transfer (arrival immigration or exit control, depending on the
        // direction — same cost either way for planning purposes).
        let connectionCountry = ReferenceData.shared.airport(inbound.arrivalIATA)?.country
        let originCountry = ReferenceData.shared.airport(inbound.departureIATA)?.country
        let destinationCountry = ReferenceData.shared.airport(outbound.arrivalIATA)?.country
        let crossesBorder = (originCountry != connectionCountry) || (destinationCountry != connectionCountry)
        if crossesBorder {
            steps.append(Step(name: "Passport control", icon: "person.text.rectangle", minutes: bigAirport ? 25 : 15))
            steps.append(Step(name: "Security recheck", icon: "figure.walk.motion", minutes: bigAirport ? 15 : 10))
        }

        steps.append(Step(name: "Walk to gate", icon: "signpost.right", minutes: bigAirport ? 12 : 7))
        steps.append(Step(name: "At gate before boarding closes", icon: "door.left.hand.open", minutes: 15))
        return steps
    }

    static func risk(neededMinutes: Int, layoverMinutes: Int) -> Risk {
        if layoverMinutes >= neededMinutes + 30 { return .relaxed }
        if layoverMinutes >= neededMinutes { return .normal }
        if layoverMinutes >= neededMinutes - 15 { return .tight }
        return .risky
    }
}
