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
    /// When this leg is meant to push back — what lets lateness propagate
    /// through the chain. Optional so rotation data cached before the field
    /// existed still decodes.
    var scheduledDeparture: Date? = nil

    /// Best-known arrival: the API's revised arrival when published, else the
    /// schedule pushed by the DEPARTURE delay — discounted for en-route
    /// recovery, because that `delay` field measures push-back lateness and
    /// schedules carry padding: a 40m-late departure rarely lands 40m late.
    /// Recovery is capped at 25m and scales with block time (~10%), so short
    /// hops recover little and the discount can never invent an early landing.
    var effectiveArrival: Date? {
        if let actualArrival { return actualArrival }
        guard let scheduledArrival else { return nil }
        var delay = Double(max(0, delayMinutes))
        if delay > 0, let scheduledDeparture {
            let blockMinutes = scheduledArrival.timeIntervalSince(scheduledDeparture) / 60
            delay = max(0, delay - min(25, blockMinutes * 0.10))
        }
        return scheduledArrival.addingTimeInterval(delay * 60)
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
        // Keyed by number + scheduled arrival, not number alone: the same
        // flight number flies daily, and merging today's and yesterday's legs
        // under one key silently truncated chains that repeat a number.
        var used: Set<String> = []
        func key(_ leg: FlightAPIClient.FlightSearchResult) -> String {
            "\(leg.flight_number)|\(leg.arr_scheduled)"
        }

        while chain.count < maxLegs {
            let candidates = legs.filter { leg in
                guard leg.flight_number != currentNumber,
                      !used.contains(key(leg)),
                      // A cancelled leg means the tail is NOT flying this
                      // path — chaining through it as if it lands on schedule
                      // manufactured a confident prediction from a fiction.
                      leg.status.lowercased() != "cancelled",
                      leg.arr_iata.uppercased() == airport.uppercased(),
                      let arrival = DateHelpers.parseAPIDate(leg.arr_scheduled)
                else { return false }
                return arrival <= cutoff
            }
            guard let leg = candidates.max(by: {
                (DateHelpers.parseAPIDate($0.arr_scheduled) ?? .distantPast) <
                (DateHelpers.parseAPIDate($1.arr_scheduled) ?? .distantPast)
            }) else { break }

            used.insert(key(leg))
            chain.append(RotationLeg(
                flightNumber: leg.flight_number,
                depIATA: leg.dep_iata,
                arrIATA: leg.arr_iata,
                scheduledArrival: DateHelpers.parseAPIDate(leg.arr_scheduled),
                actualArrival: DateHelpers.parseAPIDate(leg.arr_actual),
                delayMinutes: leg.delay ?? 0,
                status: leg.status,
                scheduledDeparture: DateHelpers.parseAPIDate(leg.dep_scheduled)))

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

    /// The whole-day version: lateness rolls forward through every remaining
    /// turnaround instead of only the immediate inbound.
    ///
    /// Each stop absorbs slack — scheduled ground time minus the minimum
    /// turnaround — and what can't be absorbed pushes the next leg. That sees
    /// trouble two airports away hours before the single-leg view can: a
    /// feeder running 50 minutes late this morning becomes tonight's delay
    /// even though tonight's inbound still reads "on time". Legs already
    /// landed contribute their actual times; legs missing a scheduled
    /// departure simply don't propagate (old cached data degrades to the
    /// single-leg behaviour, never to a wrong answer).
    static func predictChainDelay(
        chain: [RotationLeg],
        scheduledDeparture: Date,
        aircraftType: String?,
        officialDelayMinutes: Int,
        liveInboundETA: Date? = nil
    ) -> (minutes: Int, reason: String)? {
        guard !chain.isEmpty else { return nil }
        let turnaround = turnaroundMinutes(for: aircraftType)

        var carried: Date?
        var propagatedHops = 0
        for leg in chain {
            guard let schedArr = leg.scheduledArrival else { carried = nil; continue }
            var effArr = leg.effectiveArrival ?? schedArr
            // A leg still ahead of the plane can't leave before the plane is
            // there and turned around — landed legs already tell the truth.
            if let carried, let schedDep = leg.scheduledDeparture,
               leg.actualArrival == nil, leg.status != "landed" {
                let readyAt = carried.addingTimeInterval(Double(turnaround) * 60)
                let slip = readyAt.timeIntervalSince(schedDep)
                if slip > 0 {
                    let propagated = schedArr.addingTimeInterval(slip)
                    if propagated > effArr { effArr = propagated; propagatedHops += 1 }
                }
            }
            carried = effArr
        }
        // A live ADS-B fix for the airborne inbound beats every schedule
        // projection — where the plane actually is outranks where the
        // timetable says it should be.
        guard let finalArrival = liveInboundETA ?? carried else { return nil }

        let earliest = finalArrival.addingTimeInterval(Double(turnaround) * 60)
        let predicted = Int(ceil(earliest.timeIntervalSince(scheduledDeparture) / 60))
        guard predicted >= officialDelayMinutes + 10 else { return nil }
        guard predicted <= 6 * 60 else { return nil }

        let reason = propagatedHops > 0
            ? "Lateness earlier in the aircraft's day carries through each \(turnaround)-min turnaround"
            : "Inbound aircraft lands too late for a \(turnaround)-min turnaround"
        return (predicted, reason)
    }
}
