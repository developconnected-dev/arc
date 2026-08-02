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
