import Foundation

/// Shared data model between the main app and widget extension.
/// Uses App Group UserDefaults since SwiftData can't easily share across targets.
enum WidgetData {
    static let appGroupID = "group.com.arc.flighttracker"

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    // MARK: - Write (from main app)

    static func save(flights: [WidgetFlight]) {
        guard let data = try? JSONEncoder().encode(flights) else { return }
        sharedDefaults?.set(data, forKey: "widget_flights")
    }

    // MARK: - Read (from widget)

    static func loadFlights() -> [WidgetFlight] {
        guard let data = sharedDefaults?.data(forKey: "widget_flights"),
              let flights = try? JSONDecoder().decode([WidgetFlight].self, from: data)
        else { return [] }
        return flights
    }
}

/// Lightweight Codable flight for widget display.
struct WidgetFlight: Codable, Identifiable {
    let id: String
    let flightNumber: String
    let airline: String
    let departureIATA: String
    let arrivalIATA: String
    let departureCity: String
    let arrivalCity: String
    let scheduledDeparture: Date
    let scheduledArrival: Date
    let status: String
    let delayMinutes: Int
    let departureGate: String?
    let progress: Double

    var isUpcoming: Bool {
        status == "scheduled" && scheduledDeparture > .now
    }

    var isActive: Bool {
        status == "active"
    }

    var timeUntilDeparture: TimeInterval {
        scheduledDeparture.timeIntervalSince(.now)
    }

    var countdownText: String {
        let interval = timeUntilDeparture
        if interval <= 0 { return "Now" }
        let hours = Int(interval) / 3600
        let mins = (Int(interval) % 3600) / 60
        if hours > 24 {
            let days = hours / 24
            return "\(days)d \(hours % 24)h"
        }
        if hours > 0 {
            return "\(hours)h \(mins)m"
        }
        return "\(mins)m"
    }

    var statusColor: String {
        if status == "cancelled" { return "red" }
        if delayMinutes > 15 { return "orange" }
        if status == "active" { return "cyan" }
        return "green"
    }
}
