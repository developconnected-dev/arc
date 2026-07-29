import Foundation
import SwiftData

@Model
final class Flight {
    @Attribute(.unique) var id: UUID = UUID()

    // Flight identity
    var flightNumber: String = ""        // e.g. "LX17"
    var airline: String = ""             // e.g. "Swiss"
    var airlineICAO: String = ""         // e.g. "SWR"

    // Route
    var departureIATA: String = ""       // e.g. "ZRH"
    var arrivalIATA: String = ""         // e.g. "JFK"
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
    var departureTerminal: String?
    var arrivalGate: String?
    var arrivalTerminal: String?
    var baggageClaim: String?

    // Aircraft
    var aircraftType: String?            // e.g. "Airbus A340-300"
    var aircraftRegistration: String?    // e.g. "HB-JMB"
    var aircraftICAO24: String?          // For OpenSky tracking

    // Inbound tracking ("Where's My Plane") — the previous rotation of this same tail
    var inboundFlightNumber: String?
    var inboundDelayMinutes: Int = 0
    var inboundRoute: String?          // e.g. "JFK → ZRH"
    var inboundArrivalTime: Date?      // when that leg landed / is expected to land
    var inboundChecked: Bool = false   // did we ever get a real answer from the API

    // Live position (from OpenSky)
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

    // User-entered trip details
    var bookingCode: String?
    var seat: String?

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
    var notes: String = ""

    init(flightNumber: String, date: Date) {
        self.flightNumber = flightNumber
        self.scheduledDeparture = date
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
        let arrTime = estimatedArrival ?? scheduledArrival

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
