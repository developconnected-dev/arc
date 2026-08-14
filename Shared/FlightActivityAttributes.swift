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

    enum Destination: Equatable {
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

    static func parse(_ url: URL) -> Destination? {
        guard url.scheme == scheme else { return nil }
        switch url.host() {
        case "flight":
            let path = url.lastPathComponent
            if path.lowercased() != "flight", let id = UUID(uuidString: path) {
                return .flight(id: id)
            }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            func item(_ name: String) -> String? {
                items?.first(where: { $0.name == name })?.value
            }
            if let number = item("number"), let dep = item("dep"), let arr = item("arr") {
                return .flightIdentity(number: number, dep: dep, arr: arr)
            }
            return nil
        case "directions":
            let iata = url.lastPathComponent.uppercased()
            guard iata != "DIRECTIONS", !iata.isEmpty else { return nil }
            let terminal = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "t" })?.value
            return .directions(iata: iata, terminal: terminal)
        case "friend":
            let code = url.lastPathComponent
            guard !code.isEmpty, code != "friend" else { return nil }
            return .friend(code: code)
        default:
            return nil
        }
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

/// Notification taps can fire before `ArcRootView` is subscribed. Stash the
/// payload so `onAppear` can still open the flight on a cold launch.
enum PendingFlightOpen {
    static var userInfo: [AnyHashable: Any]?
}
