import Foundation
import SwiftData

/// Test/screenshot-only seeding. Runs only when the app is launched with the
/// `-seedDemo` argument and the store is empty. Never runs in normal use.
enum DemoSeed {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-seedDemo") }
    static var suppressPrompts: Bool { ProcessInfo.processInfo.arguments.contains("-uiNoPrompt") }

    static func seedIfRequested(into context: ModelContext, existing: [Flight]) {
        guard isRequested, existing.isEmpty else { return }
        let ref = ReferenceData.shared

        func make(_ number: String, _ dep: String, _ arr: String,
                  depOffsetH: Double, arrOffsetH: Double, status: String) -> Flight {
            let f = Flight(flightNumber: number, date: Date.now.addingTimeInterval(depOffsetH * 3600))
            f.airline = ref.airline(String(number.prefix(2)))?.name ?? ""
            f.airlineICAO = ref.airline(String(number.prefix(2)))?.icao ?? ""
            f.departureIATA = dep; f.arrivalIATA = arr
            if let a = ref.airport(dep) { f.departureCity = a.city; f.departureLat = a.lat; f.departureLon = a.lon }
            if let a = ref.airport(arr) { f.arrivalCity = a.city; f.arrivalLat = a.lat; f.arrivalLon = a.lon }
            f.scheduledDeparture = Date.now.addingTimeInterval(depOffsetH * 3600)
            f.scheduledArrival = Date.now.addingTimeInterval(arrOffsetH * 3600)
            f.statusRaw = status
            return f
        }

        // Active transatlantic flight with a live mid-Atlantic position.
        let active = make("LX14", "ZRH", "JFK", depOffsetH: -1.5, arrOffsetH: 7, status: "active")
        active.actualDeparture = Date.now.addingTimeInterval(-1.5 * 3600)
        active.aircraftType = "Airbus A330-300"
        active.liveLat = 55.0; active.liveLon = -25.0
        active.liveHeading = 285; active.liveAltitude = 10600; active.liveSpeed = 245
        active.liveUpdatedAt = .now
        // Recorded ADS-B breadcrumbs ZRH → mid-Atlantic, so the map draws the
        // actually-flown path (solid) + projected remainder (dashed).
        let breadcrumbs: [(Double, Double)] = [
            (48.3, 7.2), (49.6, 5.1), (50.9, 2.6), (52.0, -1.4),
            (53.0, -5.6), (53.9, -10.2), (54.5, -15.1), (54.9, -20.3),
        ]
        for (i, bc) in breadcrumbs.enumerated() {
            active.trackPoints.append(Flight.TrackPoint(
                lat: bc.0, lon: bc.1,
                timestamp: Date.now.addingTimeInterval(Double(i - breadcrumbs.count) * 600),
                altitude: 10600))
        }

        let upcoming1 = make("GQ873", "HAM", "ATH", depOffsetH: 49 * 24, arrOffsetH: 49 * 24 + 4, status: "scheduled")
        upcoming1.airline = "Sky Express"
        let upcoming2 = make("LX1413", "BEG", "ZRH", depOffsetH: 17, arrOffsetH: 19, status: "scheduled")
        upcoming2.aircraftType = "Airbus A220-300"
        upcoming2.aircraftRegistration = "HB-JCA"
        // Sample of what InboundMonitor populates from a real /inbound lookup —
        // the previous rotation of this same tail, landing at BEG before we depart.
        upcoming2.inboundFlightNumber = "LX1412"
        upcoming2.inboundRoute = "ZRH → BEG"
        upcoming2.inboundDelayMinutes = 8
        upcoming2.inboundArrivalTime = Date.now.addingTimeInterval(15 * 3600)
        upcoming2.inboundChecked = true

        // Landed 10 minutes ago — proves the 30-minute grace period keeps it
        // in My Flights (with gate/baggage still visible) before it moves
        // exclusively to Passport.
        let justLanded = make("LX1988", "VIE", "ZRH", depOffsetH: -2.5, arrOffsetH: -1.0 / 6, status: "landed")
        justLanded.actualDeparture = justLanded.scheduledDeparture
        justLanded.actualArrival = Date.now.addingTimeInterval(-10 * 60)
        justLanded.aircraftType = "Airbus A220-100"
        justLanded.arrivalGate = "A54"
        justLanded.baggageClaim = "7"

        // Delayed 12 minutes, past its own original scheduled departure, but
        // the API hasn't confirmed "active" yet — proves this stays visible
        // (My Flights + map route) instead of falling into the dead zone
        // isUpcoming used to have between "scheduled time passed" and
        // "confirmed departed."
        let overdue = make("LX1830", "ZRH", "MUC", depOffsetH: -12.0 / 60, arrOffsetH: 1, status: "scheduled")
        overdue.aircraftType = "Airbus A220-100"

        context.insert(active); context.insert(upcoming1); context.insert(upcoming2); context.insert(justLanded); context.insert(overdue)

        // Past (landed) flights so Passport stats populate.
        let past: [(String, String, String, Double, Double, String, String, Int)] = [
            // number, dep, arr, daysAgo, durationH, aircraft, reg, delayMin
            ("LX1056", "ZRH", "HAM", 17, 1.5, "Airbus A321neo", "HB-IOH", 0),
            ("U23900", "SSH", "MXP", 34, 4.3, "Airbus A321neo", "OE-IUA", 12),
            ("U23897", "MXP", "SSH", 39, 4.25, "Airbus A321neo", "OE-ISH", 0),
            ("U23950", "HAM", "MXP", 39, 1.85, "Airbus A320", "OE-LUG", 0),
            ("W67803", "EVN", "FMM", 61, 4.5, "Airbus A321neo", "HA-LVK", 26),
            ("W67804", "FMM", "EVN", 64, 4.4, "Airbus A320", "HA-LWX", 0),
            ("LX317", "ZRH", "LHR", 78, 1.75, "Airbus A220-300", "HB-JCA", 0),
        ]
        for p in past {
            let f = make(p.0, p.1, p.2, depOffsetH: -p.3 * 24, arrOffsetH: -p.3 * 24 + p.4, status: "landed")
            f.aircraftType = p.5
            f.aircraftRegistration = p.6
            f.delayMinutes = p.7
            // Keep actual times consistent with the recorded delay (a delayed
            // landed flight shouldn't also claim it arrived exactly on schedule).
            let delaySeconds = Double(p.7) * 60
            f.actualDeparture = f.scheduledDeparture.addingTimeInterval(delaySeconds)
            f.actualArrival = f.scheduledArrival.addingTimeInterval(delaySeconds)
            context.insert(f)
        }

        // A cancelled flight — proves it stays visible in Passport history
        // instead of vanishing (it's neither upcoming nor landed).
        let cancelled = make("LX2312", "ZRH", "VIE", depOffsetH: -12 * 24, arrOffsetH: -12 * 24 + 1.3, status: "cancelled")
        cancelled.aircraftType = "Airbus A220-100"
        cancelled.aircraftRegistration = "HB-AZK"
        context.insert(cancelled)

        try? context.save()
    }

    /// One-off verification hook, `-seedStuckFlight`: seeds a real flight
    /// (LX53, BOS→ZRH, actually landed hours ago per a live API check) but
    /// pinned at `.scheduled` — exactly the state a flight could get
    /// permanently stuck in before the isUpcoming fix, since nothing would
    /// ever poll it again to learn it had gone active/landed. Proves the fix
    /// self-heals: FlightTracker starts on launch, this flight is now
    /// eligible for polling again, one real API round-trip corrects its
    /// status, and it should show up in Passport without any manual action.
    static var isStuckFlightRequested: Bool { ProcessInfo.processInfo.arguments.contains("-seedStuckFlight") }

    static func seedStuckFlightIfRequested(into context: ModelContext, existing: [Flight]) {
        guard isStuckFlightRequested, existing.isEmpty else { return }
        let ref = ReferenceData.shared
        let f = Flight(flightNumber: "LX53", date: Date(timeIntervalSince1970: 1784511600))   // 2026-07-20T01:40:00Z
        f.airline = ref.airline("LX")?.name ?? "Swiss"
        f.airlineICAO = ref.airline("LX")?.icao ?? ""
        f.departureIATA = "BOS"; f.arrivalIATA = "ZRH"
        if let a = ref.airport("BOS") { f.departureCity = a.city; f.departureLat = a.lat; f.departureLon = a.lon }
        if let a = ref.airport("ZRH") { f.arrivalCity = a.city; f.arrivalLat = a.lat; f.arrivalLon = a.lon }
        f.scheduledDeparture = Date(timeIntervalSince1970: 1784511600)   // 2026-07-20T01:40:00Z
        f.scheduledArrival = Date(timeIntervalSince1970: 1784537700)     // 2026-07-20T08:55:00Z
        f.statusRaw = "scheduled"   // stuck — should self-heal to "landed" once tracking starts
        context.insert(f)
        try? context.save()
    }
}
