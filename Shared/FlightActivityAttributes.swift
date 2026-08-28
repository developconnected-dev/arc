import Foundation
import ActivityKit

struct FlightActivityAttributes: ActivityAttributes {
    let flightNumber: String
    let departureIATA: String
    let arrivalIATA: String
    let departureCity: String
    let arrivalCity: String
    let airline: String
    let aircraftType: String?
    let seat: String?
    /// Set when this activity tracks a FRIEND's flight — the widget shows
    /// whose flight it is where the seat would normally go.
    var friendName: String? = nil
    /// Filename of a pre-scaled avatar PNG in the shared App Group container
    /// (`la-avatars/<file>`). Widgets can't load network images, so the app
    /// stages the friend's profile picture there before starting the
    /// activity; absent (older activities, push-to-start) the widget falls
    /// back to the generic person icon.
    var friendAvatarFile: String? = nil
    /// The friend's `shared_flights` row id — what a tap on THEIR card
    /// routes by. Without it the tap resolved the friend's flight number
    /// against the viewer's OWN store: a switch to My Trips with nothing
    /// opened, or the viewer's same-numbered flight. nil on own cards and
    /// on friend cards started before this field existed.
    var friendFlightId: String? = nil
    /// Local SwiftData id, so tapping the Live Activity opens THAT flight.
    /// Optional: push-to-start from the Worker doesn't know it, and those
    /// activities fall back to number + route.
    var flightId: String? = nil
    /// Raw `TripMode`, optional so activities started before the field existed
    /// (and pushes from an older Worker) still decode. Absent = air.
    var modeRaw: String? = nil
    /// Raw `DataTier`. Absent (older activities, Worker pushes) = live, which
    /// is what every activity was before trains and ferries existed.
    var dataTierRaw: String? = nil

    /// Each end's own zone — the rule every other Arc surface already follows,
    /// and the one this card was the last to break.
    ///
    /// `Text(date, style: .time)` renders in the DEVICE's zone, so a Zurich
    /// phone printed a Heathrow arrival as "18:55 LHR" for a flight that lands
    /// at 17:55 London time: a number that contradicts the very label beside
    /// it. The home-screen widget had zones and got it right; only the Live
    /// Activity carried none, so it could not have got it right.
    ///
    /// Optional, so activities started before this existed — and pushes from
    /// an older Worker — still decode, falling back to the device zone.
    var departureTZID: String? = nil
    var arrivalTZID: String? = nil

    /// Wall-clock at one end, as that place reads it. Same formatter and same
    /// fallback as `WidgetFlight.localTime`.
    func localTime(_ date: Date, zone id: String?) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = id.flatMap(TimeZone.init(identifier:)) ?? .current
        return f.string(from: date)
    }
    func depTime(_ date: Date) -> String { localTime(date, zone: departureTZID) }
    func arrTime(_ date: Date) -> String { localTime(date, zone: arrivalTZID) }

    var mode: TripMode { TripMode(rawValue: modeRaw ?? "") ?? .air }
    var dataTier: DataTier { DataTier(rawValue: dataTierRaw ?? "") ?? .live }
    /// Only a live source may say "On Time" — same rule as the app.
    var reportsPunctuality: Bool { dataTier.reportsPunctuality }

    /// A friend on the SAME flight, shown on the traveller's own activity —
    /// avatar and seat in the header instead of a whole second card for one
    /// plane. Lives in ContentState so a friend adding the flight mid-journey
    /// appears on the next update.
    struct Companion: Codable, Hashable {
        var name: String
        var seat: String? = nil
        /// Pre-staged PNG in the App Group ("la-avatars/<file>") — widgets
        /// can't load network images.
        var avatarFile: String? = nil
    }

    struct ContentState: Codable, Hashable {
        let status: String
        let departureTime: Date
        let arrivalTime: Date
        let boardingTime: Date?     // typically 30-45 min before departure
        let delayMinutes: Int
        /// Arrival-side delay, from the provider's revised arrival time.
        /// Optional so pushes from an older Worker still decode (falls back
        /// to `delayMinutes` in the widget).
        var arrivalDelayMinutes: Int? = nil
        /// The "smart line": one short sentence of understanding (delay
        /// trend, knock-on expectation, time made up in the air), phrased
        /// server-side by the Worker's AI from structured signals. Optional
        /// on the wire; absent = the widget simply shows nothing extra.
        var insight: String? = nil
        /// Friends on this same flight. Optional with a default so pushes
        /// from an older Worker and stored states still decode.
        var companions: [Companion]? = nil
        /// When this state was built — the insight shimmer's sweep replays
        /// from here on every update. Optional for older stored states.
        var updatedAt: Date? = nil
        let departureGate: String?
        let departureTerminal: String?
        let arrivalGate: String?
        let arrivalTerminal: String?
        let baggageClaim: String?
        let progress: Double
        // What Arc knows about the gate-to-runway gap (see DepartureEvidence).
        // All optional with defaults so pushes from an older Worker, and
        // states stored before any of this existed, still decode. `offBlock`
        // is carried separately from `departureTime` because that one prefers
        // a confirmed take-off, and the taxi is measured from the gate.
        var offBlock: Date? = nil
        var estimatedTakeoff: Date? = nil
        var actualDeparture: Date? = nil
        var groundState: String? = nil
        var groundObservedAt: Date? = nil
        var taxiStartedAt: Date? = nil
        var lastSeenOnGround: Date? = nil
        var taxiPriorMinutes: Int? = nil

        /// The lock screen's own copy of the question every Arc surface
        /// answers the same way.
        var departureEvidence: DepartureEvidence {
            DepartureEvidence(
                offBlock: offBlock ?? departureTime,
                estimatedTakeoff: estimatedTakeoff,
                actualDeparture: actualDeparture,
                groundState: groundState,
                groundObservedAt: groundObservedAt,
                taxiStartedAt: taxiStartedAt,
                lastSeenOnGround: lastSeenOnGround,
                taxiPriorMinutes: taxiPriorMinutes ?? DepartureEvidence.defaultTaxiPrior)
        }

        func departurePhase(at date: Date) -> DeparturePhase {
            if status == "landed" || status == "diverted" { return .airborne }
            if status == "cancelled" { return .beforeDeparture }
            let phase = departureEvidence.phase(at: date)
            if status == "active", phase == .beforeDeparture { return .airborne }
            return phase
        }

        /// When the wheels are expected to leave the ground — what staleDate
        /// is pointed at, so the lock screen changes its mind at the right
        /// moment with no app running and no network.
        var expectedWheelsUp: Date { departureEvidence.expectedWheelsUp }
    }
}

/// `arc://` URLs shared by the app, the home-screen widget, and the Live Activity.
enum ArcDeepLink {
    static let scheme = "arc"

    enum Destination: Equatable, Sendable {
        case flight(id: UUID)
        case flightIdentity(number: String, dep: String, arr: String)
        /// A FRIEND's flight, named by its `shared_flights` row id. Separate
        /// from `flight(id:)` because that one resolves against the reader's
        /// own SwiftData store, and a friend's flight was never in it — which
        /// is why a tapped "landed" alert had nowhere to go.
        case friendFlight(id: String)
        case directions(iata: String, terminal: String?)
        case friend(code: String)
    }

    static func flight(id: UUID) -> URL {
        URL(string: "\(scheme)://flight/\(id.uuidString)")!
    }

    static func flight(number: String, dep: String, arr: String) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "flight"
        c.queryItems = [
            URLQueryItem(name: "number", value: number),
            URLQueryItem(name: "dep", value: dep),
            URLQueryItem(name: "arr", value: arr),
        ]
        return c.url!
    }

    static func flight(widget: WidgetFlight) -> URL {
        if let id = UUID(uuidString: widget.id) { return flight(id: id) }
        return flight(number: widget.flightNumber, dep: widget.departureIATA, arr: widget.arrivalIATA)
    }

    static func friendFlight(id: String) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "friendflight"
        c.path = "/\(id)"
        return c.url ?? URL(string: "\(scheme)://friendflight")!
    }

    static func url(for attributes: FlightActivityAttributes) -> URL {
        // A FRIEND's card routes to the friend's flight. Resolving its
        // number against the viewer's own store — the fallback below —
        // either missed entirely (a tab switch with nothing opened) or
        // landed on the viewer's own same-numbered flight.
        if attributes.friendName != nil, let raw = attributes.friendFlightId {
            return friendFlight(id: raw)
        }
        if let raw = attributes.flightId, let id = UUID(uuidString: raw) {
            return flight(id: id)
        }
        return flight(number: attributes.flightNumber,
                      dep: attributes.departureIATA,
                      arr: attributes.arrivalIATA)
    }

    /// Everything goes through `URLComponents`: the host of a custom-scheme URL
    /// is the first segment, and splitting `path` keeps `arc://flight/<uuid>`
    /// (one path segment) cleanly apart from `arc://flight?number=…` (none) —
    /// `lastPathComponent` returns the host for the second form on some
    /// platforms, which made the two indistinguishable.
    static func parse(_ url: URL) -> Destination? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              comps.scheme?.lowercased() == scheme
        else { return nil }
        let parts = comps.path.split(separator: "/").map(String.init)
        func query(_ name: String) -> String? {
            comps.queryItems?.first(where: { $0.name == name })?.value
        }
        switch comps.host?.lowercased() {
        case "flight":
            if let first = parts.first, let id = UUID(uuidString: first) {
                return .flight(id: id)
            }
            if let number = query("number"), let dep = query("dep"), let arr = query("arr") {
                return .flightIdentity(number: number, dep: dep, arr: arr)
            }
            return nil
        case "directions":
            guard let iata = parts.first?.uppercased(), !iata.isEmpty else { return nil }
            return .directions(iata: iata, terminal: query("t"))
        case "friendflight":
            guard let id = parts.first, !id.isEmpty else { return nil }
            return .friendFlight(id: id)
        case "friend":
            guard let code = parts.first, !code.isEmpty else { return nil }
            return .friend(code: code)
        default:
            return nil
        }
    }

    /// The same routing, but from a local notification's `userInfo` — so a
    /// tapped delay alert lands on exactly the flight it was about.
    static func destination(fromNotificationUserInfo info: [AnyHashable: Any]) -> Destination? {
        // Checked FIRST: a friend alert names a row in `shared_flights`, and
        // resolving that against the reader's own flights would either miss or,
        // worse, land on a same-numbered flight of their own.
        if let raw = info[ArcOpenFlightInfo.friendId] as? String, !raw.isEmpty {
            return .friendFlight(id: raw)
        }
        if let raw = info[ArcOpenFlightInfo.id] as? String, let id = UUID(uuidString: raw) {
            return .flight(id: id)
        }
        if let number = info[ArcOpenFlightInfo.number] as? String,
           let dep = info[ArcOpenFlightInfo.dep] as? String,
           let arr = info[ArcOpenFlightInfo.arr] as? String {
            return .flightIdentity(number: number, dep: dep, arr: arr)
        }
        return nil
    }
}

extension Notification.Name {
    /// Posted when a notification, widget, or Live Activity asks to open a flight.
    static let arcOpenFlight = Notification.Name("arcOpenFlight")
}

enum ArcOpenFlightInfo {
    static let id = "flightId"
    /// A friend's `shared_flights` row id.
    static let friendId = "friendFlightId"
    static let number = "flightNumber"
    static let dep = "dep"
    static let arr = "arr"
}

/// A notification tap can be delivered before `ArcRootView` subscribes, and on
/// a cold launch before SwiftData has any flights to match. The destination
/// parks here until the root view can actually act on it.
@MainActor
enum PendingFlightOpen {
    static var destination: ArcDeepLink.Destination?
}
