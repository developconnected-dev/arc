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

    struct ContentState: Codable, Hashable {
        let status: String
        let departureTime: Date
        let arrivalTime: Date
        let boardingTime: Date?     // typically 30-45 min before departure
        let securityWaitMinutes: Int?  // live security queue estimate
        let delayMinutes: Int
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
