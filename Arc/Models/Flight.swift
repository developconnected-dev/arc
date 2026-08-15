import Foundation
import SwiftData

/// One booked leg of a trip — historically a flight, now also a train or a
/// ferry sailing.
///
/// The name stays `Flight` deliberately. Renaming a `@Model` is a schema
/// migration against journeys the user already has stored, and this type is
/// referenced from the widget, the Live Activity attributes and the Supabase
/// payload keys, so a rename would ripple through all three for no behavioural
/// gain. `mode` carries what actually differs; the display layer supplies the
/// vocabulary.
@Model
final class Flight {
    @Attribute(.unique) var id: UUID = UUID()

    // MARK: - Mode
    //
    // Defaulted so every leg already on the device migrates untouched: SwiftData
    // adds a property with a default value without a migration plan.

    var modeRaw: String = "air"
    var mode: TripMode {
        get { TripMode(rawValue: modeRaw) ?? .air }
        set { modeRaw = newValue.rawValue }
    }

    /// How much the source really knows — see `DataTier`. Existing rows are all
    /// AeroDataBox-tracked flights, so `live` is the correct default for them.
    var dataTierRaw: String = "live"
    var dataTier: DataTier {
        get { DataTier(rawValue: dataTierRaw) ?? .live }
        set { dataTierRaw = newValue.rawValue }
    }

    // Flight identity
    var flightNumber: String = ""        // e.g. "LX17" / "ICE 373" / "BLUE STAR DELOS"
    /// The codeshare number this flight was BOOKED under, when that differs
    /// from the number that operates it — "A31653" on a flight stored as
    /// LH1751. Only the operating number can be tracked (nothing indexes a
    /// marketing number at range), but only the marketing one appears on the
    /// ticket, so the ticket's number is kept for display.
    var marketingFlightNumber: String?
    var airline: String = ""             // e.g. "Swiss"
    var airlineICAO: String = ""         // e.g. "SWR"

    // Route
    //
    // These two stay SHORT — three characters — in every mode. They are rendered
    // raw into fixed-width chips in the list row, the home widget and the
    // Dynamic Island, none of which wrap. A rail stop id like
    // "de-DELFI_de:11000:900003201" in this field would wreck all three, so the
    // provider's real handle lives in `departureStopID` and this holds the
    // three letters that go on screen (derived from the station or port name).
    // Display-only: nothing is ever looked up by these outside air mode, so a
    // collision with a real IATA code is harmless.
    var departureIATA: String = ""       // e.g. "ZRH" / "BER" / "PIR"
    var arrivalIATA: String = ""         // e.g. "JFK" / "BAS" / "THI"

    /// The provider's own identifier for each endpoint, opaque and often long.
    ///
    /// Rail: the MOTIS stop id, which must be the one the DEPARTURE BOARD gave
    /// (`place.stopId`) — the id used to query a board is frequently a different
    /// DHID station from the one trips report, because a large Hauptbahnhof is
    /// several stations that a traveller experiences as one place.
    /// Sea: the port NAME, because Ferryhopper's search resolves names and
    /// rejects codes ("PIR" finds nothing, "Piraeus" finds seven sailings).
    var departureStopID: String?
    var arrivalStopID: String?

    /// IANA zone per endpoint, for the modes where the airport table can't answer.
    ///
    /// `ReferenceData.timezone` resolves an IATA code against the bundled airport
    /// database. That is exactly wrong for a station or a port: "PIR" is not an
    /// airport, and worse, some derived codes DO collide with real airports and
    /// would silently return a plausible zone for the wrong continent. So rail
    /// and sea legs carry their own zone and the display layer prefers it.
    var departureTZID: String?
    var arrivalTZID: String?
    var departureCity: String = ""       // e.g. "Zurich"
    var arrivalCity: String = ""         // e.g. "New York"
    var departureLat: Double = 0
    var departureLon: Double = 0
    var arrivalLat: Double = 0
    var arrivalLon: Double = 0

    // Times
    var scheduledDeparture: Date = Date()
    var scheduledArrival: Date = Date()
    var actualDeparture: Date?
    var actualArrival: Date?
    var estimatedArrival: Date?

    // Status
    var statusRaw: String = "scheduled"  // scheduled, active, landed, cancelled, diverted
    var delayMinutes: Int = 0

    // Gate & terminal
    var departureGate: String?
    var previousDepartureGate: String?
    var departureTerminal: String?
    var arrivalGate: String?
    var arrivalTerminal: String?
    var baggageClaim: String?

    // Aircraft
    var aircraftType: String?            // e.g. "Airbus A340-300"
    var aircraftRegistration: String?    // e.g. "HB-JMB"
    var aircraftICAO24: String?          // The tail's ADS-B transponder address

    // MARK: - Vessel (sea)

    var vesselName: String?              // e.g. "BLUE STAR DELOS"

    /// Maritime Mobile Service Identity, for AIS position tracking.
    ///
    /// Kept apart from `aircraftICAO24` rather than reusing it, because that
    /// field is what feeds the OpenSky lookup. An MMSI is nine decimal digits
    /// where an ICAO24 is six hex, so a shared field would let a ferry's id
    /// reach the aircraft tracker and come back with a position belonging to
    /// something else entirely — wrong, and with nothing to raise an error.
    /// `livePositionSource` dispatches on `mode`, never on whichever is set.
    var vesselMMSI: String?

    // MARK: - Ground/water extras

    /// Operator artwork, supplied by the ferry source (airlines use the bundled
    /// asset catalog instead).
    var operatorLogoURL: String?

    /// The operator's own words about this sailing being moved or cancelled.
    ///
    /// The only change signal ferries have: no Mediterranean source publishes a
    /// per-sailing revised time, so a disruption notice is the entire substance
    /// of "is my ferry still running". Shown verbatim rather than parsed into a
    /// delay figure, because parsing prose into a number would manufacture a
    /// precision the operator never stated.
    var disruptionNote: String?
    var disruptionSeenAt: Date?

    /// Deep link back to the source for a sailing, so a changed booking can be
    /// re-checked where it was made.
    var bookingURL: String?

    /// The leg's real routed path, JSON-encoded [[lat, lon], …].
    ///
    /// A great-circle arc is right for a plane and false for a train: it draws
    /// Berlin→Basel straight across the countryside instead of routing via
    /// Frankfurt and Mannheim. MOTIS publishes the actual track; the Worker
    /// decodes and simplifies it to a few hundred points (~3–6 KB) so the map
    /// can draw the real line without carrying 110 KB per leg.
    ///
    /// nil for flights (a great circle IS the route) and for ferries (no
    /// provider publishes sailing geometry), and both fall back to the arc.
    var routePathData: Data?

    /// The identity of a booked train that survives the feed being re-imported.
    ///
    /// MOTIS trip ids embed a per-import sequence number that is renumbered when
    /// the feed rebuilds, so a train added weeks ahead would quietly stop
    /// resolving. `railTripID` is kept as a fast path and re-derived from the
    /// departure board — matched on operator, service number, boarding stop and
    /// scheduled time — whenever it fails.
    var railTripID: String?

    // Inbound tracking ("Where's My Plane") — the previous rotation of this same tail
    var inboundFlightNumber: String?
    var inboundDelayMinutes: Int = 0
    var inboundRoute: String?          // e.g. "JFK → ZRH"
    var inboundArrivalTime: Date?      // when that leg landed / is expected to land
    var inboundChecked: Bool = false   // did we ever get a real answer from the API

    // Live position (ADS-B)
    var liveLat: Double?
    var liveLon: Double?
    var liveAltitude: Double?            // meters
    var liveSpeed: Double?               // m/s
    var liveHeading: Double?             // degrees
    var liveUpdatedAt: Date?

    // Flight path breadcrumbs — actual positions collected during flight.
    // Stored as JSON-encoded array of [lat, lon, timestamp] triples.
    // Used to draw the real flight path on the map instead of a generic arc.
    var trackPointsData: Data?

    // The aircraft's full day (JSON-encoded [RotationLeg]) leading up to this
    // flight, plus Arc's own knock-on delay prediction derived from it —
    // shown alongside the airline's official number, never replacing it.
    var rotationData: Data?
    var predictedDelayMinutes: Int = 0
    var predictionReason: String?
    /// Snapshot of `predictedDelayMinutes` frozen at the moment the flight
    /// went active — so after landing, the prediction can be checked against
    /// what actually happened instead of quietly forgotten.
    var predictedDelayAtDeparture: Int = 0
    /// The "your aircraft has arrived" notification fires exactly once.
    var inboundArrivedNotified: Bool = false

    // User-entered trip details
    var bookingCode: String?
    var seat: String?

    /// Entered by hand because no schedule was published yet. Arc keeps
    /// checking once a day, however far out the flight is, and fills in the
    /// real times the moment the airline files them.
    var awaitingSchedule: Bool = false
    var lastScheduleCheckAt: Date?

    /// Who this flight is shared with, as friend profile ids.
    ///
    /// `nil` means everyone you're friends with — the behaviour before this
    /// existed, and the default for a new flight, so adding one never shares
    /// less than it used to. An empty array means nobody: the row is pulled
    /// from `shared_flights` entirely rather than uploaded with no audience.
    /// Groups aren't stored here; they're a way to pick people, and picking
    /// resolves to the members at that moment.
    var sharedWithIds: [String]?

    // Meta
    var isFriend: Bool = false           // Is this a friend's flight?
    var friendName: String?
    var addedAt: Date = Date()
    var lastStatusUpdate: Date?          // Last time API status was successfully refreshed
    var notes: String = ""

    init(flightNumber: String, date: Date) {
        self.flightNumber = flightNumber
        self.scheduledDeparture = date
    }

    /// Intelligent offline / data freshness indicator text.
    ///
    /// "Offline" is a claim about the DEVICE, so it's only made when the
    /// device is actually offline — stale data while connected just says how
    /// old it is ("Updated 17m ago"), because the likely cause is the source
    /// having nothing new for this flight, not a lost connection.
    @MainActor var dataFreshnessText: String {
        let online = NetworkMonitor.shared.isConnected
        guard let updateTime = lastStatusUpdate ?? liveUpdatedAt else {
            return online ? "Schedule • No live data yet" : "Offline • Cached Schedule"
        }
        let interval = Date.now.timeIntervalSince(updateTime)
        let age: String = if interval < 3600 {
            "\(max(1, Int(interval / 60)))m ago"
        } else if interval < 86400 {
            "\(Int(interval / 3600))h ago"
        } else {
            "\(Int(interval / 86400))d ago"
        }
        if interval < 60 { return "Live • Just updated" }
        if interval < 600 { return "Live • \(age)" }
        return online ? "Updated \(age)" : "Offline • Cached \(age)"
    }

    /// Row-sized freshness. The full sentence ("Offline • Cached 12m ago") is
    /// fine on the detail screen, but in a list row it shared its line with
    /// both endpoints and squeezed them until "ATH" broke to two lines and
    /// "13:39" to three.
    var dataFreshnessShort: String {
        guard let updateTime = lastStatusUpdate ?? liveUpdatedAt else { return "—" }
        let interval = Date.now.timeIntervalSince(updateTime)
        if interval < 60 { return "Live" }
        if interval < 3600 { return "\(max(1, Int(interval / 60)))m" }
        if interval < 86400 { return "\(max(1, Int(interval / 3600)))h" }
        return "\(Int(interval / 86400))d"
    }

    var isDataFresh: Bool {
        guard let updateTime = lastStatusUpdate ?? liveUpdatedAt else { return false }
        return Date.now.timeIntervalSince(updateTime) < 600
    }

    var status: FlightStatus {
        get { FlightStatus(rawValue: statusRaw) ?? .scheduled }
        set { statusRaw = newValue.rawValue }
    }

    /// "Still scheduled" — i.e. not yet confirmed departed, landed, cancelled,
    /// or diverted. Deliberately does NOT require `scheduledDeparture > .now`:
    /// that extra check created a permanent tracking dead zone for any flight
    /// still marked `.scheduled` after its original scheduled time passed
    /// (the overwhelmingly common case — any delay at all means the real
    /// airline hasn't reported "departed" by the moment the original schedule
    /// time ticks over). FlightTracker only re-polls flights that are
    /// isUpcoming, isActive, or isRecentlyLanded — so a flight that briefly
    /// satisfied none of the three, right as its schedule time passed but
    /// before the API confirmed departure, would drop out of tracking and
    /// never be checked again, never learning it had actually gone active.
    /// The same condition also gates My Flights/map visibility, so this was
    /// the flight vanishing "the moment it takes off." `status` alone — not a
    /// time comparison — is what actually answers "do we know this departed
    /// yet," so that's what this checks.
    var isUpcoming: Bool {
        status == .scheduled || status == .boarding || status == .gateClosed
    }

    var isBoarding: Bool {
        status == .boarding || status == .gateClosed
    }

    var isActive: Bool {
        status == .active
    }

    var isCompleted: Bool {
        status == .landed || status == .cancelled || status == .diverted
    }

    /// Where a live position for this leg can be fetched from, if anywhere.
    ///
    /// Dispatches on `mode` rather than on whichever identifier happens to be
    /// populated. That distinction is load-bearing: handing a nine-digit MMSI to
    /// the ICAO24-based aircraft lookup returns a position for some other
    /// vehicle, or none, and reports no error either way.
    ///
    /// Trains return `nil` — no free Europe-wide source publishes live train
    /// positions, so a rail leg's map arc is drawn from its timetable progress.
    var livePositionSource: LivePositionSource? {
        switch mode {
        case .air:
            guard let id = aircraftICAO24?.trimmingCharacters(in: .whitespaces),
                  !id.isEmpty else { return nil }
            return .openSky(icao24: id)
        case .sea:
            guard let id = vesselMMSI?.trimmingCharacters(in: .whitespaces),
                  id.count == 9, id.allSatisfy(\.isNumber) else { return nil }
            return .ais(mmsi: id)
        case .rail:
            return nil
        }
    }

    var duration: TimeInterval {
        scheduledArrival.timeIntervalSince(scheduledDeparture)
    }

    var durationFormatted: String {
        let hours = Int(duration) / 3600
        let mins = (Int(duration) % 3600) / 60
        return "\(hours)h \(mins)m"
    }

    /// Great circle distance in kilometers
    var distanceKm: Double {
        let R = 6371.0
        let dLat = (arrivalLat - departureLat) * .pi / 180
        let dLon = (arrivalLon - departureLon) * .pi / 180
        let a = sin(dLat/2) * sin(dLat/2) +
                cos(departureLat * .pi / 180) * cos(arrivalLat * .pi / 180) *
                sin(dLon/2) * sin(dLon/2)
        let c = 2 * atan2(sqrt(a), sqrt(1-a))
        return R * c
    }

    var distanceFormatted: String {
        if distanceKm > 10000 {
            return String(format: "%.0fK km", distanceKm / 1000)
        }
        return String(format: "%.0f km", distanceKm)
    }

    /// Flight progress 0..1 based on time
    var progress: Double {
        let depTime = actualDeparture ?? scheduledDeparture.addingTimeInterval(Double(delayMinutes) * 60)
        // Delay shifts the arrival too — otherwise a delayed flight reads
        // 100% while still airborne.
        let arrTime = estimatedArrival ?? scheduledArrival.addingTimeInterval(Double(delayMinutes) * 60)

        // If arrival time has passed, flight is done
        if Date.now >= arrTime { return 1.0 }

        // If departure time hasn't passed, no progress yet
        if Date.now < depTime { return 0.0 }

        // In between: compute time-based progress regardless of status string
        // This ensures the arc moves even if the API didn't update status to "active"
        let total = arrTime.timeIntervalSince(depTime)
        guard total > 0 else { return 0 }
        return min(1.0, max(0, Date.now.timeIntervalSince(depTime) / total))
    }

    // MARK: - Smarter Arrival ETA

    /// Estimated arrival computed from actual departure + scheduled flight duration,
    /// rather than just adding departure delay to scheduled arrival.
    /// When live position data is available, computes ETA from remaining distance / speed.
    var smartETA: Date {
        // If API provided an actual/estimated arrival, trust it
        if let est = estimatedArrival { return est }
        if let actual = actualArrival { return actual }

        // Compute from actual departure + scheduled flight duration
        // This naturally gives a better ETA because airlines pad schedules
        let flightDuration = scheduledArrival.timeIntervalSince(scheduledDeparture)
        let depTime = actualDeparture ?? scheduledDeparture.addingTimeInterval(Double(delayMinutes) * 60)

        // If we have live position and speed, compute remaining distance ETA
        if let lat = liveLat, let lon = liveLon, let speed = liveSpeed, speed > 10 {
            let remainingKm = greatCircleDistance(
                lat1: lat, lon1: lon,
                lat2: arrivalLat, lon2: arrivalLon
            )
            let remainingSeconds = (remainingKm * 1000) / speed  // speed is m/s
            let liveETA = Date.now.addingTimeInterval(remainingSeconds)

            // Sanity check: live ETA should be within reasonable range
            let scheduledETA = depTime.addingTimeInterval(flightDuration)
            if liveETA > depTime && liveETA < scheduledETA.addingTimeInterval(3600) {
                return liveETA
            }
        }

        return depTime.addingTimeInterval(flightDuration)
    }

    private func greatCircleDistance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let R = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat/2) * sin(dLat/2) +
                cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) *
                sin(dLon/2) * sin(dLon/2)
        let c = 2 * atan2(sqrt(a), sqrt(1-a))
        return R * c
    }

    // MARK: - Flight Path Breadcrumbs

    struct TrackPoint: Codable {
        let lat: Double
        let lon: Double
        let timestamp: Date
        let altitude: Double? // meters
    }

    /// Decoded track points from stored JSON data
    var trackPoints: [TrackPoint] {
        get {
            guard let data = trackPointsData else { return [] }
            return (try? JSONDecoder().decode([TrackPoint].self, from: data)) ?? []
        }
        set {
            trackPointsData = try? JSONEncoder().encode(newValue)
        }
    }

    /// Decoded route path, empty when the leg has none.
    var routePath: [(lat: Double, lon: Double)] {
        guard let data = routePathData,
              let raw = try? JSONDecoder().decode([[Double]].self, from: data) else { return [] }
        return raw.compactMap { $0.count >= 2 ? (lat: $0[0], lon: $0[1]) : nil }
    }

    /// The tail's day so far, chronological (immediate inbound last).
    var rotationLegs: [RotationLeg] {
        get {
            guard let data = rotationData else { return [] }
            return (try? JSONDecoder().decode([RotationLeg].self, from: data)) ?? []
        }
        set {
            rotationData = try? JSONEncoder().encode(newValue)
        }
    }

    /// True when Arc's own prediction says meaningfully more than the airline
    /// has admitted — the only case where showing it adds information.
    var showsPrediction: Bool {
        (status == .scheduled || status == .boarding) && predictedDelayMinutes >= delayMinutes + 10
    }

    /// Append a new position breadcrumb. Called by FlightTracker each time
    /// OpenSky returns a position. Deduplicates by checking distance from last point.
    func appendTrackPoint(lat: Double, lon: Double, altitude: Double?) {
        var points = trackPoints

        // Skip if too close to last point (< 2 km) to avoid bloating storage
        if let last = points.last {
            let dist = greatCircleDistance(lat1: last.lat, lon1: last.lon, lat2: lat, lon2: lon)
            if dist < 2.0 { return }
        }

        points.append(TrackPoint(lat: lat, lon: lon, timestamp: .now, altitude: altitude))

        // Cap at 500 points max (~8 hours at 60s intervals)
        if points.count > 500 { points = Array(points.suffix(500)) }

        trackPoints = points
    }
}

extension Flight {
    /// The one true delete. Three screens deleted flights three different
    /// ways — the detail menu left the flight in the family's shared feed,
    /// the lists left a Live Activity running, and one ended the activity in
    /// a Task racing the deletion (touching a deleted model). Everything a
    /// removal involves lives here, in a safe order: end the Live Activity
    /// and read what we need BEFORE the model dies, then clean up remotely.
    @MainActor
    static func delete(_ flight: Flight, from context: ModelContext) async {
        let id = flight.id
        let number = flight.flightNumber
        let departure = flight.scheduledDeparture
        await LiveActivityManager.shared.endActivity(for: flight)
        ArcNotifications.removeAll(for: flight)
        context.delete(flight)
        try? context.save()
        Task {
            try? await ArcSupabase.shared.deleteUserFlight(id: id)
            try? await ArcSupabase.shared.unshareFlight(flightNumber: number, scheduledDeparture: departure)
            // Open "travelling with" invites die with the trip — otherwise a
            // friend could still Accept a journey nobody's on any more.
            try? await ArcSupabase.shared.withdrawTripInvites(flightNumber: number, scheduledDeparture: departure)
        }
    }
}

/// Which live-position provider can track a given leg, and the identifier it
/// wants. Modelled as one value so the two id namespaces can never be confused
/// at a call site.
enum LivePositionSource: Equatable, Sendable {
    case openSky(icao24: String)
    case ais(mmsi: String)
}

enum FlightStatus: String, Codable, CaseIterable {
    case scheduled
    case boarding      // from AeroDataBox: passengers boarding
    case gateClosed    // from AeroDataBox: gate closed, about to depart
    case active
    case landed
    case cancelled
    case diverted

    /// Best-effort recovery for a status string that isn't one of our 5 raw
    /// values — either a foreign API string that slipped past the Worker's
    /// normalization, or already-stored bad data from before that existed.
    /// Falls back to a date-based heuristic rather than blindly assuming
    /// "scheduled", so a clearly-past flight doesn't get stuck looking upcoming.
    static func heal(rawValue: String, scheduledArrival: Date) -> FlightStatus {
        if let known = FlightStatus(rawValue: rawValue) { return known }
        return scheduledArrival < .now ? .landed : .scheduled
    }
}
