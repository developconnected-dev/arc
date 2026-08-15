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

    var mode: TripMode { TripMode(rawValue: modeRaw ?? "") ?? .air }
    var dataTier: DataTier { DataTier(rawValue: dataTierRaw ?? "") ?? .live }
    /// Only a live source may say "On Time" — same rule as the app.
    var reportsPunctuality: Bool { dataTier.reportsPunctuality }

    struct ContentState: Codable, Hashable {
        let status: String
        let departureTime: Date
        let arrivalTime: Date
        let boardingTime: Date?     // typically 30-45 min before departure
        let securityWaitMinutes: Int?  // live security queue estimate
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
        let departureGate: String?
        let departureTerminal: String?
        let arrivalGate: String?
        let arrivalTerminal: String?
        let baggageClaim: String?
        let altitude: Double?
        let speed: Double?
        let heading: Double?
        let progress: Double
    }
}

/// `arc://` URLs shared by the app, the home-screen widget, and the Live Activity.
enum ArcDeepLink {
    static let scheme = "arc"

    enum Destination: Equatable, Sendable {
        case flight(id: UUID)
        case flightIdentity(number: String, dep: String, arr: String)
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

    static func url(for attributes: FlightActivityAttributes) -> URL {
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
