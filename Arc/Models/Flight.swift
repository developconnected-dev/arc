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

    // User-entered trip details
    var bookingCode: String?
    var seat: String?

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
        status == .scheduled
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
        guard status == .active else {
            return status == .landed ? 1.0 : 0.0
        }
        let total = scheduledArrival.timeIntervalSince(scheduledDeparture)
        let elapsed = Date.now.timeIntervalSince(actualDeparture ?? scheduledDeparture)
        guard total > 0 else { return 0 }
        return min(1.0, max(0, elapsed / total))
    }
}

enum FlightStatus: String, Codable, CaseIterable {
    case scheduled
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
