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

    /// Status-only, no clock comparison — mirrors Flight.isUpcoming. The old
    /// `&& scheduledDeparture > .now` had the same dead zone the app model
    /// did: any delayed flight past its original scheduled time (but not yet
    /// confirmed departed) vanished from the widget exactly when the user
    /// most wants to see it.
    var isUpcoming: Bool {
        status == "scheduled" || status == "boarding" || status == "gateClosed"
    }

    var isActive: Bool {
        status == "active"
    }

    /// Departure adjusted by the known delay — what countdowns should target.
    var effectiveDeparture: Date {
        scheduledDeparture.addingTimeInterval(Double(max(0, delayMinutes)) * 60)
    }

    var effectiveArrival: Date {
        scheduledArrival.addingTimeInterval(Double(max(0, delayMinutes)) * 60)
    }

    enum Phase { case upcoming, inFlight, landed }

    /// Phase as of a given moment — CLOCK-based, not status-string-based.
    /// The stored status only changes when the app runs; widget timeline
    /// entries render at future dates while the app may be closed and the
    /// device offline. Deriving the phase from the entry's own date is what
    /// makes the pre-flight → in-flight → landed layout switch happen
    /// automatically without the user ever opening the app. A trusted status
    /// (active/landed from the API) still wins when it's ahead of the clock.
    func phase(at date: Date) -> Phase {
        if status == "landed" || status == "cancelled" || status == "diverted" { return .landed }
        if status == "active" { return date >= effectiveArrival ? .landed : .inFlight }
        if date >= effectiveArrival { return .landed }
        if date >= effectiveDeparture { return .inFlight }
        return .upcoming
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
