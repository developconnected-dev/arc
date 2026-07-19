import Foundation
import ActivityKit

struct FlightActivityAttributes: ActivityAttributes {
    let flightNumber: String
    let departureIATA: String
    let arrivalIATA: String
    let airline: String

    struct ContentState: Codable, Hashable {
        let status: String
        let progress: Double
        let departureTime: Date
        let arrivalTime: Date
        let delayMinutes: Int
        let gate: String?
    }
}
