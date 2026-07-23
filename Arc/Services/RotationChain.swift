import Foundation

/// One leg of an aircraft's day — a link in the chain of flights the tail
/// works before it becomes YOUR flight.
struct RotationLeg: Codable, Equatable {
    let flightNumber: String
    let depIATA: String
    let arrIATA: String
    let scheduledArrival: Date?
    let actualArrival: Date?
    let delayMinutes: Int
    let status: String

    /// Best-known arrival: actual if reported, else scheduled + known delay.
    var effectiveArrival: Date? {
        if let actualArrival { return actualArrival }
        guard let scheduledArrival else { return nil }
        return scheduledArrival.addingTimeInterval(Double(max(0, delayMinutes)) * 60)
    }
}

/// Pure logic for full-day tail tracking and knock-on delay prediction.
/// Separate from `InboundMonitor` (which does the networking) so every rule
/// here is unit-testable without a live API call.
enum RotationChain {

    /// Walks a tail's day backwards from this flight: the leg that lands at
    /// our departure airport before we leave, then the leg that fed THAT one,
    /// and so on — the plane's whole journey toward us, in chronological
    /// order (earliest first, immediate inbound last).
    static func buildChain(
        from legs: [FlightAPIClient.FlightSearchResult],
        endingAt departureIATA: String,
        before departure: Date,
        excludingFlightNumber currentNumber: String,
        maxLegs: Int = 4
    ) -> [RotationLeg] {
        var chain: [RotationLeg] = []
        var airport = departureIATA
        var cutoff = departure
        var used: Set<String> = [currentNumber]

        while chain.count < maxLegs {
            let candidates = legs.filter { leg in
                guard !used.contains(leg.flight_number),
                      leg.arr_iata.uppercased() == airport.uppercased(),
                      let arrival = DateHelpers.parseAPIDate(leg.arr_scheduled)
                else { return false }
                return arrival <= cutoff
            }
            guard let leg = candidates.max(by: {
                (DateHelpers.parseAPIDate($0.arr_scheduled) ?? .distantPast) <
                (DateHelpers.parseAPIDate($1.arr_scheduled) ?? .distantPast)
            }) else { break }

            used.insert(leg.flight_number)
            chain.append(RotationLeg(
                flightNumber: leg.flight_number,
                depIATA: leg.dep_iata,
                arrIATA: leg.arr_iata,
                scheduledArrival: DateHelpers.parseAPIDate(leg.arr_scheduled),
                actualArrival: DateHelpers.parseAPIDate(leg.arr_actual),
                delayMinutes: leg.delay ?? 0,
                status: leg.status))

            airport = leg.dep_iata
            cutoff = DateHelpers.parseAPIDate(leg.dep_scheduled)
                ?? DateHelpers.parseAPIDate(leg.arr_scheduled) ?? cutoff
        }

        return chain.reversed()
    }

    /// Minimum realistic turnaround for an aircraft type, in minutes — how
    /// fast a crew can plausibly deplane, clean, board, and push back again.
    /// Deliberately on the optimistic side: predictions built on it are a
    /// FLOOR ("it can't leave earlier than this"), never an overstatement.
    static func turnaroundMinutes(for aircraftType: String?) -> Int {
        let t = (aircraftType ?? "").uppercased()
        let widebodies = ["747", "777", "787", "A330", "A340", "A350", "A380", "767"]
        if widebodies.contains(where: { t.contains($0) }) { return 60 }
        let smallRegional = ["A220", "E17", "E19", "E29", "CRJ", "ATR", "DASH", "DH8"]
        if smallRegional.contains(where: { t.contains($0) }) { return 30 }
        return 35   // narrowbody default (A320 family, 737, etc.)
    }

    /// Knock-on delay prediction from the inbound aircraft — the ~35%-of-all-
    /// delays cause airlines are slowest to admit. If the plane physically
    /// can't be ready before `scheduledDeparture`, say so before the airline
    /// does. Returns nil unless we'd predict meaningfully MORE than the
    /// airline has already published (their number wins otherwise), and nil
    /// for implausible (>6h) results that smell like bad data.
    static func predictDelay(
        inboundEffectiveArrival: Date,
        scheduledDeparture: Date,
        aircraftType: String?,
        officialDelayMinutes: Int
    ) -> (minutes: Int, reason: String)? {
        let turnaround = turnaroundMinutes(for: aircraftType)
        let earliestDeparture = inboundEffectiveArrival.addingTimeInterval(Double(turnaround) * 60)
        let predicted = Int(ceil(earliestDeparture.timeIntervalSince(scheduledDeparture) / 60))

        guard predicted >= officialDelayMinutes + 10 else { return nil }
        guard predicted <= 6 * 60 else { return nil }

        return (predicted, "Inbound aircraft lands too late for a \(turnaround)-min turnaround")
    }
}
