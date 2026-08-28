import Foundation
import ActivityKit
import UserNotifications

/// How much you care about one friend's flying, decided per friend and
/// stored locally (it's about what THIS device shows, not shared state).
enum FriendNotificationLevel: String, CaseIterable, Identifiable {
    case live      // Live Activity while they fly + alerts
    case notify    // takeoff / landing / delay alerts (default)
    case off       // feed and map only, never interrupts

    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: "Live Activity + Alerts"
        case .notify: "Alerts Only"
        case .off: "Off"
        }
    }
    var shortTitle: String {
        switch self {
        case .live: "Live"
        case .notify: "Alerts"
        case .off: "Off"
        }
    }
    var icon: String {
        switch self {
        case .live: "dot.radiowaves.left.and.right"
        case .notify: "bell"
        case .off: "bell.slash"
        }
    }
}

/// Friend-flight alerting: diffs each refresh against a PERSISTED baseline
/// (a background launch starts with empty memory — without persistence the
/// takeoff your girlfriend's flight just made would never fire) and posts
/// local notifications + manages friend Live Activities accordingly.
@MainActor
enum FriendAlerts {
    // MARK: - Per-friend level

    static func level(for friendId: String) -> FriendNotificationLevel {
        FriendNotificationLevel(
            rawValue: UserDefaults.standard.string(forKey: "friendNotify.\(friendId)") ?? ""
        ) ?? .notify
    }

    static func setLevel(_ level: FriendNotificationLevel, for friendId: String) {
        UserDefaults.standard.set(level.rawValue, forKey: "friendNotify.\(friendId)")
    }

    // MARK: - Events (pure, baseline-diffed)

    struct Event: Equatable {
        enum Kind: Equatable { case tookOff, landed, delayed(Int) }
        let friendName: String
        let flightId: String
        let flightNumber: String
        let route: String
        let arrivalCity: String
        let kind: Kind
    }

    /// Baseline value format: "<phase>|<delayMinutes>".
    nonisolated static func events(
        baseline: [String: String],
        flights: [(user: ArcSupabase.ArcUser, flight: ArcSupabase.SharedFlight)],
        levels: [String: FriendNotificationLevel],
        at now: Date
    ) -> [Event] {
        var out: [Event] = []
        for (user, f) in flights {
            guard (levels[user.id] ?? .notify) != .off else { continue }
            // First sight of a flight records silently — no spam when a
            // friend connects mid-trip or the baseline was empty.
            guard let prior = baseline[f.id] else { continue }
            let parts = prior.split(separator: "|")
            let priorPhase = FriendFlightMath.Phase(rawValue: String(parts.first ?? "")) ?? .upcoming
            let priorDelay = Int(parts.count > 1 ? parts[1] : "0") ?? 0
            let phase = FriendFlightMath.phase(f, at: now)

            let event: Event.Kind?
            if priorPhase != .airborne && phase == .airborne {
                event = .tookOff
            } else if priorPhase != .landed && phase == .landed {
                event = .landed
            } else if phase == .upcoming, f.delay_minutes >= priorDelay + 15 {
                event = .delayed(f.delay_minutes)
            } else {
                event = nil
            }
            if let event {
                out.append(Event(
                    friendName: user.display_name,
                    flightId: f.id,
                    flightNumber: f.flight_number,
                    route: "\(f.departure_iata) → \(f.arrival_iata)",
                    arrivalCity: f.arrival_city,
                    kind: event))
            }
        }
        return out
    }

    nonisolated static func baselineValue(_ f: ArcSupabase.SharedFlight, at now: Date) -> String {
        "\(FriendFlightMath.phase(f, at: now).rawValue)|\(f.delay_minutes)"
    }

    // MARK: - Processing (called from every FriendsStore refresh)

    private static let baselineKey = "friendAlerts.baseline"

    static func process(entries: [FriendsStore.FriendEntry], at now: Date = .now) async {
        let baseline = (UserDefaults.standard.dictionary(forKey: baselineKey) as? [String: String]) ?? [:]
        // A cancelled flight has no take-off, landing or delay to announce.
        let flights = entries.flatMap { entry in
            entry.flights.filter { $0.status != "cancelled" }.map { (entry.user, $0) }
        }
        // Tolerant keying: a duplicate entry must degrade, never trap.
        let levels = Dictionary(entries.map { ($0.id, level(for: $0.id)) },
                                uniquingKeysWith: { a, _ in a })

        for event in events(baseline: baseline, flights: flights, levels: levels, at: now) {
            post(event)
        }

        // New baseline: exactly the flights we can still see.
        var fresh: [String: String] = [:]
        for (_, f) in flights { fresh[f.id] = baselineValue(f, at: now) }
        UserDefaults.standard.set(fresh, forKey: baselineKey)

        await manageLiveActivities(entries: entries, levels: levels, at: now)
    }

    /// What a friend alert carries so a tap can find its way back.
    nonisolated static func userInfo(forFlightId id: String) -> [String: String] {
        [ArcOpenFlightInfo.friendId: id]
    }

    private static func post(_ event: Event) {
        let content = UNMutableNotificationContent()
        switch event.kind {
        case .tookOff:
            content.title = "\(event.friendName) is in the air ✈️"
            content.body = "\(event.flightNumber) \(event.route)"
        case .landed:
            content.title = "\(event.friendName) landed in \(event.arrivalCity) 🛬"
            content.body = "\(event.flightNumber) \(event.route)"
        case .delayed(let minutes):
            content.title = "\(event.friendName)'s flight is \(minutes)m late"
            content.body = "\(event.flightNumber) \(event.route)"
        }
        content.sound = .default
        // Without this the tap had nothing to act on: the handler's
        // `guard let destination` bailed and the notification opened whatever
        // the app last showed, which is not the flight it was announcing.
        content.userInfo = userInfo(forFlightId: event.flightId)
        // Identifier doubles as dedupe: one notification per flight+kind.
        let kindKey = switch event.kind {
        case .tookOff: "tookoff"; case .landed: "landed"; case .delayed: "delayed"
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "friend-\(event.flightId)-\(kindKey)",
            content: content, trigger: nil))
    }

    /// Live-level friends get a Live Activity from 1h before departure until
    /// 45m after landing. If YOU are on the same flight, your own activity
    /// already exists and the duplicate guard leaves it alone.
    private static func manageLiveActivities(
        entries: [FriendsStore.FriendEntry],
        levels: [String: FriendNotificationLevel],
        at now: Date
    ) async {
        for entry in entries {
            guard let f = entry.spotlight else { continue }
            let isLive = levels[entry.id] == .live
            let phase = FriendFlightMath.phase(f, at: now)
            let arrival = FriendFlightMath.arrival(f)

            // On the SAME flight, the friend belongs on the traveller's own
            // card (avatar + seat in the header) — a second full activity for
            // one plane is noise, and the lock screen only shows two anyway.
            let norm = f.flight_number.replacingOccurrences(of: " ", with: "").uppercased()
            let onMyOwnFlight = Activity<FlightActivityAttributes>.activities.contains {
                $0.attributes.friendName == nil &&
                $0.attributes.flightNumber.replacingOccurrences(of: " ", with: "").uppercased() == norm &&
                $0.attributes.departureIATA == f.departure_iata
            }
            if !isLive || onMyOwnFlight
                || (phase == .landed && (arrival.map { now > $0.addingTimeInterval(45 * 60) } ?? true)) {
                await LiveActivityManager.shared.endFriendActivity(
                    flightNumber: f.flight_number, departureIATA: f.departure_iata)
                continue
            }

            let startsSoon = FriendFlightMath.departure(f)
                .map { $0.timeIntervalSince(now) < 3600 && $0 > now } ?? false
            guard phase == .airborne || phase == .landed || startsSoon else { continue }

            let flight = FriendsStore.shared.transientFlight(
                for: .init(user: entry.user, flight: f))
            // Stage the avatar in the App Group first — the widget can only
            // render what's already on disk when the activity starts.
            let avatarFile = await LiveActivityAvatarStore.ensureAvatar(
                userId: entry.user.id, urlString: entry.user.avatar_url)
            await LiveActivityManager.shared.startActivity(
                for: flight, friendName: entry.user.display_name,
                friendAvatarFile: avatarFile, friendFlightId: f.id)
            await LiveActivityManager.shared.updateActivity(for: flight, friendName: entry.user.display_name)
        }
    }
}
