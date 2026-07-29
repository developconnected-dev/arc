import Foundation
import UserNotifications

/// Schedules local notifications for flight events.
/// Respects user preferences from Settings.
enum ArcNotifications {

    private static var prefs: UserDefaults { .standard }

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - Scheduled Alerts

    /// Schedule departure reminder (2 hours before)
    static func scheduleDepartureReminder(for flight: Flight) {
        guard prefs.object(forKey: "notifyDepartureReminder") == nil || prefs.bool(forKey: "notifyDepartureReminder") else { return }

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: flight.scheduledDeparture.addingTimeInterval(-2 * 3600)
            ),
            repeats: false
        )

        let content = UNMutableNotificationContent()
        content.title = "\(flight.flightNumber) departs in 2 hours"
        content.body = "\(flight.departureIATA) → \(flight.arrivalIATA) • \(flight.airline)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "departure-\(flight.flightNumber)-\(Int(flight.scheduledDeparture.timeIntervalSince1970))",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Instant Alerts

    static func notifyGateChange(flight: Flight, newGate: String) {
        guard prefs.object(forKey: "notifyGateChanges") == nil || prefs.bool(forKey: "notifyGateChanges") else { return }
        send(
            title: "Gate changed — \(flight.flightNumber)",
            body: "New gate: \(newGate)",
            id: "gate-\(flight.flightNumber)-\(newGate)"
        )
    }

    static func notifyDelay(flight: Flight) {
        guard prefs.object(forKey: "notifyDelays") == nil || prefs.bool(forKey: "notifyDelays") else { return }
        guard flight.delayMinutes > 0 else { return } // Don't notify on delay improvements
        send(
            title: "\(flight.flightNumber) delayed",
            body: "Now \(flight.delayMinutes) min late. \(flight.departureIATA) → \(flight.arrivalIATA)",
            id: "delay-\(flight.flightNumber)-\(flight.delayMinutes)"
        )
    }

    static func notifyLanded(flight: Flight) {
        guard prefs.object(forKey: "notifyLanding") == nil || prefs.bool(forKey: "notifyLanding") else { return }
        var body = "\(flight.departureIATA) → \(flight.arrivalIATA)"
        if let gate = flight.arrivalGate { body += " • Gate \(gate)" }
        if let baggage = flight.baggageClaim { body += " • Belt \(baggage)" }

        send(
            title: "\(flight.flightNumber) has landed",
            body: body,
            id: "landed-\(flight.flightNumber)"
        )
    }

    /// Arc's own knock-on prediction — fires BEFORE the airline admits a
    /// delay, which is the whole point. Deduped by predicted magnitude.
    static func notifyPredictedDelay(flight: Flight, minutes: Int) {
        guard prefs.object(forKey: "notifyDelays") == nil || prefs.bool(forKey: "notifyDelays") else { return }
        send(
            title: "\(flight.flightNumber) likely delayed",
            body: "Arc predicts ~\(minutes) min late — the inbound aircraft is running behind. The airline hasn't updated the schedule yet.",
            id: "predicted-\(flight.flightNumber)-\(minutes)"
        )
    }

    /// Connection risk got worse (delays ate the layover buffer).
    static func notifyConnectionRisk(_ plan: ConnectionPlanner.Plan) {
        send(
            title: "Connection now \(plan.risk.rawValue.lowercased())",
            body: "\(plan.layoverMinutes) min layover in \(plan.inbound.arrivalCity) — you need about \(plan.neededMinutes) min. \(plan.outbound.flightNumberSpaced) departs \(plan.outbound.effectiveDepTimeLocal).",
            id: "connection-\(plan.outbound.flightNumber)-\(plan.risk.rawValue)"
        )
    }

    static func notifyCancelled(flight: Flight) {
        send(
            title: "\(flight.flightNumber) cancelled",
            body: "\(flight.departureIATA) → \(flight.arrivalIATA) has been cancelled.",
            id: "cancelled-\(flight.flightNumber)"
        )
    }

    /// The payoff for a flight added by hand before its schedule existed: the
    /// airline has now filed it and Arc has replaced the typed times.
    static func scheduleFound(_ flight: Flight) {
        send(
            title: "\(flight.flightNumber) schedule confirmed",
            body: "\(flight.departureIATA) → \(flight.arrivalIATA) now has real times from the airline.",
            id: "schedule-found-\(flight.flightNumber)-\(Int(flight.scheduledDeparture.timeIntervalSince1970))"
        )
    }

    // MARK: - Cleanup

    static func removeAll(for flight: Flight) {
        let flightNum = flight.flightNumber
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let ids = requests
                .filter { $0.identifier.hasPrefix("departure-\(flightNum)") ||
                          $0.identifier.hasPrefix("gate-\(flightNum)") ||
                          $0.identifier.hasPrefix("delay-\(flightNum)") ||
                          $0.identifier.hasPrefix("predicted-\(flightNum)") ||
                          $0.identifier.hasPrefix("landed-\(flightNum)") ||
                          $0.identifier.hasPrefix("cancelled-\(flightNum)") }
                .map(\.identifier)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    // MARK: - Private

    private static func send(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
