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

    /// 2h before the *effective* departure (delay-adjusted), or nil if that
    /// moment has already passed — so a delayed flight still reminds at the
    /// useful time, and a reminder in the past is never scheduled.
    static func departureReminderDate(for flight: Flight, now: Date = .now) -> Date? {
        let fire = flight.effectiveDeparture.addingTimeInterval(-2 * 3600)
        return fire > now ? fire : nil
    }

    /// Schedule departure reminder (2 hours before)
    static func scheduleDepartureReminder(for flight: Flight) {
        guard prefs.object(forKey: "notifyDepartureReminder") == nil || prefs.bool(forKey: "notifyDepartureReminder") else { return }

        guard let fire = departureReminderDate(for: flight) else { return }

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: fire
            ),
            repeats: false
        )

        let content = UNMutableNotificationContent()
        content.title = "\(flight.flightNumber) departs in 2 hours"
        content.body = "\(flight.departureIATA) → \(flight.arrivalIATA) • \(flight.airline)"
        content.sound = .default
        content.userInfo = [ArcOpenFlightInfo.id: flight.id.uuidString]

        let request = UNNotificationRequest(
            identifier: "departure-\(flight.flightNumber)-\(Int(flight.scheduledDeparture.timeIntervalSince1970))",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Instant Alerts

    /// The Worker's own watcher covers cancellations, delays and gates for
    /// flights more than three hours out, and it can say them with the app
    /// closed — which these cannot. Inside three hours the watcher stands
    /// down (a Live Activity is running by then) and these are the alert.
    ///
    /// Facts the SERVER cannot know — Arc's knock-on prediction, the inbound
    /// aircraft landing — are never suppressed: nothing else would say them.
    private static func serverWillSayIt(_ flight: Flight, now: Date = .now) -> Bool {
        RemotePush.isRegistered
            && flight.mode == .air
            && flight.effectiveDeparture.timeIntervalSince(now) > 3 * 3600
    }

    static func notifyGateChange(flight: Flight, newGate: String) {
        guard prefs.object(forKey: "notifyGateChanges") == nil || prefs.bool(forKey: "notifyGateChanges") else { return }
        guard !serverWillSayIt(flight) else { return }
        send(
            // Platform changes are the rail equivalent, and they arrive through
            // this same path — so the word has to come from the mode.
            title: "\(flight.mode.boardingPointLabel) changed — \(flight.flightNumber)",
            body: "New \(flight.mode.boardingPointLabel.lowercased()): \(newGate)",
            id: "gate-\(flight.flightNumber)-\(newGate)",
            flight: flight
        )
    }

    static func notifyDelay(flight: Flight) {
        guard prefs.object(forKey: "notifyDelays") == nil || prefs.bool(forKey: "notifyDelays") else { return }
        guard flight.delayMinutes > 0 else { return } // Don't notify on delay improvements
        guard !serverWillSayIt(flight) else { return }
        send(
            title: "\(flight.flightNumber) delayed",
            body: "Now \(flight.delayMinutes) min late. \(flight.departureIATA) → \(flight.arrivalIATA)",
            id: "delay-\(flight.flightNumber)-\(flight.delayMinutes)",
            flight: flight
        )
    }

    static func notifyLanded(flight: Flight) {
        guard prefs.object(forKey: "notifyLanding") == nil || prefs.bool(forKey: "notifyLanding") else { return }
        var body = "\(flight.departureIATA) → \(flight.arrivalIATA)"
        if let gate = flight.arrivalGate { body += " • \(flight.mode.boardingPointLabel) \(gate)" }
        if let baggage = flight.baggageClaim { body += " • Belt \(baggage)" }

        send(
            // A train does not land.
            title: "\(flight.flightNumber) has \(flight.mode.arrivedVerb.lowercased())",
            body: body,
            id: "landed-\(flight.flightNumber)-\(Int(flight.scheduledDeparture.timeIntervalSince1970))",
            flight: flight
        )
    }

    /// Arc's own knock-on prediction — fires BEFORE the airline admits a
    /// delay, which is the whole point. Deduped by predicted magnitude.
    static func notifyPredictedDelay(flight: Flight, minutes: Int) {
        guard prefs.object(forKey: "notifyDelays") == nil || prefs.bool(forKey: "notifyDelays") else { return }
        send(
            title: "\(flight.flightNumber) likely delayed",
            body: "Arc predicts ~\(minutes) min late — the inbound aircraft is running behind. The airline hasn't updated the schedule yet.",
            id: "predicted-\(flight.flightNumber)-\(minutes)",
            flight: flight
        )
    }

    /// The best possible pre-departure news, pushed instead of buried in a
    /// card: the tail that flies YOUR leg is on the ground at your airport.
    static func notifyInboundArrived(flight: Flight) {
        guard prefs.object(forKey: "notifyDelays") == nil || prefs.bool(forKey: "notifyDelays") else { return }
        send(
            title: "Your aircraft has arrived",
            body: "The plane for \(flight.flightNumberSpaced) is on the ground at \(flight.departureCity). Departure \(flight.effectiveDepTimeLocal).",
            id: "inbound-arrived-\(flight.flightNumber)-\(Int(flight.scheduledDeparture.timeIntervalSince1970))",
            flight: flight
        )
    }

    /// Connection risk got worse (delays ate the layover buffer).
    static func notifyConnectionRisk(_ plan: ConnectionPlanner.Plan) {
        send(
            title: "Connection now \(plan.risk.rawValue.lowercased())",
            body: "\(plan.layoverMinutes) min layover in \(plan.inbound.arrivalCity) — you need about \(plan.neededMinutes) min. \(plan.outbound.flightNumberSpaced) departs \(plan.outbound.effectiveDepTimeLocal).",
            id: "connection-\(plan.outbound.flightNumber)-\(plan.risk.rawValue)",
            flight: plan.outbound
        )
    }

    static func notifyCancelled(flight: Flight) {
        guard !serverWillSayIt(flight) else { return }
        send(
            title: "\(flight.flightNumber) cancelled",
            body: "\(flight.departureIATA) → \(flight.arrivalIATA) has been cancelled.",
            id: "cancelled-\(flight.flightNumber)-\(Int(flight.scheduledDeparture.timeIntervalSince1970))",
            flight: flight
        )
    }

    /// "Anna is at ZRH too" — fired once per friend-and-airport, because the
    /// useful moment is discovery: it's when you can still go and find them.
    /// The identifier doubles as the dedupe key, so re-detecting the same
    /// overlap on the next refresh doesn't buzz again.
    static func notifyAirportOverlap(_ overlap: FriendsStore.AirportOverlap) {
        send(
            title: "\(overlap.friend.display_name) is at \(overlap.airportIATA) too",
            body: "You're both there \(overlap.isToday ? "today" : "in the same window") · \(overlap.timeWindow).",
            id: "overlap-\(overlap.friend.id)-\(overlap.airportIATA)",
            flightId: overlap.myFlightId
        )
    }

    /// "Carl added a trip for you together" — the invite waits at the top of
    /// My Trips; opening the app is enough, so no flight id rides along (the
    /// trip isn't the user's yet).
    static func notifyTripInvite(_ item: FriendsStore.TripInviteItem) {
        let f = item.invite.flight
        let route = [f.departure_city, f.arrival_city].compactMap { $0 }.filter { !$0.isEmpty }
        let when = DateHelpers.parseAPIDate(f.scheduled_departure)
            .map { $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }
        let detail = [route.isEmpty ? nil : route.joined(separator: " → "), when]
            .compactMap { $0 }.joined(separator: " · ")
        send(
            title: "\(item.sender.display_name) added a trip for you together",
            body: detail.isEmpty ? "Accept it in My Trips to add it to your list."
                                 : "\(detail). Accept it in My Trips to add it to your list.",
            id: "trip-invite-\(item.id)"
        )
    }

    /// The payoff for a flight added by hand before its schedule existed: the
    /// airline has now filed it and Arc has replaced the typed times.
    static func scheduleFound(_ flight: Flight) {
        send(
            title: "\(flight.flightNumber) schedule confirmed",
            body: "\(flight.departureIATA) → \(flight.arrivalIATA) now has real times from the airline.",
            id: "schedule-found-\(flight.flightNumber)-\(Int(flight.scheduledDeparture.timeIntervalSince1970))",
            flight: flight
        )
    }

    /// Remove the reminder tied to one specific (old) departure time — used
    /// when the backfill replaces a typed time. Targeted by exact id, so it
    /// can never race the newly scheduled replacement.
    static func removeDepartureReminder(flightNumber: String, scheduledDeparture: Date) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [
            "departure-\(flightNumber)-\(Int(scheduledDeparture.timeIntervalSince1970))",
        ])
    }

    // MARK: - Cleanup

    static func removeAll(for flight: Flight) {
        let flightNum = flight.flightNumber
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            // Match the id's own separator or its end — flight numbers are
            // prefix-ambiguous, and a bare hasPrefix("departure-LX17") also
            // swept away LX178's reminder.
            let ids = requests
                .filter { id in
                    ["departure-\(flightNum)-", "gate-\(flightNum)-", "delay-\(flightNum)-",
                     "predicted-\(flightNum)-", "landed-\(flightNum)-",
                     "cancelled-\(flightNum)-", "inbound-arrived-\(flightNum)-"]
                        .contains(where: id.identifier.hasPrefix)
                }
                .map(\.identifier)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    // MARK: - Private

    private static func send(title: String, body: String, id: String, flight: Flight? = nil, flightId: UUID? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let openId = flight?.id ?? flightId {
            content.userInfo = [ArcOpenFlightInfo.id: openId.uuidString]
        }

        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
