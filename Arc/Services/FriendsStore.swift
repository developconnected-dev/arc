import Foundation
import SwiftUI
import CoreLocation

/// One shared source of truth for the Friends feature: the friend list, each
/// friend's synced flights, and which flight to spotlight per friend. Both
/// the Friends tab UI and the shared map read from here, so one refresh
/// serves both (friend profiles + ALL friends' flights = 2 round-trips).
@MainActor
@Observable
final class FriendsStore {
    static let shared = FriendsStore()

    struct FriendEntry: Identifiable {
        let friendshipId: String
        let user: ArcSupabase.ArcUser
        var flights: [ArcSupabase.SharedFlight]
        var id: String { user.id }

        /// The one flight worth talking about: flying now beats boarding
        /// soon beats "landed earlier today" beats anything upcoming later.
        var spotlight: ArcSupabase.SharedFlight? {
            FriendFlightMath.spotlight(from: flights)
        }
    }

    var friends: [FriendEntry] = []
    var pending: [(friendship: ArcSupabase.Friendship, user: ArcSupabase.ArcUser)] = []
    var isLoading = false
    var lastError: String?
    private var lastRefreshAt: Date?

    /// Invite code from an arc://friend/<code> link, waiting for a session.
    /// (Opening a link can precede profile setup — the code parks here until
    /// there's a signed-in user to redeem it with.)
    var pendingInviteCode: String?
    /// Set after a successful redeem — drives the "You and X are now sharing
    /// flights" confirmation.
    var justRedeemedFriend: ArcSupabase.ArcUser?

    func redeemPendingIfPossible() async {
        guard let code = pendingInviteCode,
              ArcSupabase.shared.currentUser != nil else { return }
        pendingInviteCode = nil
        if let friend = try? await ArcSupabase.shared.redeemInvite(code: code) {
            justRedeemedFriend = friend
            lastRefreshAt = nil   // force the next refresh through the throttle
            await refresh()
        }
    }

    /// Selected friend filter from the Friends' Flights list — the map
    /// mirrors it, so filtering to Anna also filters the globe to Anna.
    var mapFilterFriendId: String?

    /// Set when a friend-flight detail opens: the globe zooms onto this
    /// route; cleared on dismiss (the camera re-frames all friends).
    struct FocusedRoute: Equatable {
        let id: String
        let dep: CLLocationCoordinate2D
        let arr: CLLocationCoordinate2D
        static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    }
    var focusedRoute: FocusedRoute?

    /// A friend-flight as a map bubble (Flighty): airborne rides the route
    /// at clock progress (or the live ADS-B fix), upcoming sits at the
    /// departure airport, freshly landed sits at the arrival airport — each
    /// with the avatar and a live status pill.
    struct FriendMapOverlay: Identifiable {
        let id: String
        let name: String
        let dep: CLLocationCoordinate2D
        let arr: CLLocationCoordinate2D
        let progress: Double
        let live: CLLocationCoordinate2D?
        let airborne: Bool
        let landed: Bool
        let avatarURL: String?
        /// Every flight draws its arc; only the friend's ongoing-or-next
        /// flight carries the avatar bubble — so a friend with three
        /// bookings shows three arcs but one face.
        let showsBubble: Bool
        let chipText: String
        let chipKind: FriendFlightMath.ChipKind
    }

    /// Bumped once a minute while the Friends tab is visible — SwiftUI only
    /// re-derives overlay positions on render, so without this an airborne
    /// bubble would sit still while the user just watches the map.
    var clockTick = 0

    var mapOverlays: [FriendMapOverlay] {
        _ = clockTick   // observation hook: the minute tick re-derives positions
        var items = feed
        if let id = mapFilterFriendId { items = items.filter { $0.user.id == id } }
        // The feed is priority-sorted (airborne → upcoming → landed), so the
        // first item per friend is exactly their ongoing-or-next flight.
        var bubbleOwners = Set<String>()
        return items.compactMap { item in
            let f = item.flight
            guard let dlat = f.departure_lat, let dlon = f.departure_lon,
                  let alat = f.arrival_lat, let alon = f.arrival_lon,
                  dlat != 0 || dlon != 0
            else { return nil }
            let chip = FriendFlightMath.chip(for: f)
            // A live ADS-B fix beats clock interpolation only while FRESH:
            // friends are offline in the air, so their last fix is usually
            // from right after takeoff — trusting it forever would pin the
            // bubble near the departure airport for the whole flight.
            let liveFresh = DateHelpers.parseAPIDate(f.updated_at)
                .map { Date.now.timeIntervalSince($0) < 15 * 60 } ?? false
            return FriendMapOverlay(
                id: f.id,
                name: item.user.display_name,
                dep: .init(latitude: dlat, longitude: dlon),
                arr: .init(latitude: alat, longitude: alon),
                progress: FriendFlightMath.progress(f),
                live: (liveFresh && f.live_lat != nil && f.live_lon != nil)
                    ? .init(latitude: f.live_lat!, longitude: f.live_lon!) : nil,
                airborne: FriendFlightMath.isAirborne(f),
                landed: chip.kind == .landed,
                avatarURL: item.user.avatar_url,
                showsBubble: bubbleOwners.insert(item.user.id).inserted,
                chipText: chip.text,
                chipKind: chip.kind)
        }
    }

    /// One friend-flight in the Friends' Flights feed.
    struct FeedItem: Identifiable {
        let user: ArcSupabase.ArcUser
        let flight: ArcSupabase.SharedFlight
        var id: String { flight.id }
    }

    /// The flight-centric feed (Flighty's Friends' Flights): every friend's
    /// relevant flights in one list — airborne first (soonest landing on
    /// top), then everything still to come (soonest departure first), then
    /// flights landed in the last 24h.
    ///
    /// Upcoming has no far horizon on purpose: families book holidays months
    /// ahead, and the whole point of adding someone is seeing the trip they
    /// already have. Sorting by departure keeps distant flights at the bottom
    /// without hiding them.
    var feed: [FeedItem] { feed(at: .now) }

    func feed(at now: Date) -> [FeedItem] {
        var ranked: [(item: FeedItem, bucket: Int, order: TimeInterval)] = []
        for entry in friends {
            for f in entry.flights where f.status != "cancelled" {
                let item = FeedItem(user: entry.user, flight: f)
                if FriendFlightMath.isAirborne(f, at: now), let arr = FriendFlightMath.arrival(f) {
                    ranked.append((item, 0, arr.timeIntervalSince1970))
                } else if let dep = FriendFlightMath.departure(f), dep > now {
                    ranked.append((item, 1, dep.timeIntervalSince1970))
                } else if let arr = FriendFlightMath.arrival(f), arr <= now,
                          arr > now.addingTimeInterval(-24 * 3600) {
                    ranked.append((item, 2, -arr.timeIntervalSince1970))
                }
            }
        }
        return ranked
            .sorted { ($0.bucket, $0.order) < ($1.bucket, $1.order) }
            .map(\.item)
    }

    /// A display-only Flight model — NOT inserted into SwiftData — so a
    /// friend's flight opens the exact same detail screen as the user's own
    /// flights. Edits made there (seat, notes) simply don't persist, which
    /// is correct: it isn't your flight.
    func transientFlight(for item: FeedItem) -> Flight {
        let f = item.flight
        let scheduledDep = DateHelpers.parseAPIDate(f.scheduled_departure) ?? .now
        let scheduledArr = DateHelpers.parseAPIDate(f.scheduled_arrival)
            ?? scheduledDep.addingTimeInterval(2 * 3600)
        let flight = Flight(flightNumber: f.flight_number, date: scheduledDep)
        flight.airline = f.airline
        flight.airlineICAO = String(f.flight_number.prefix(2))
        flight.departureIATA = f.departure_iata
        flight.arrivalIATA = f.arrival_iata
        flight.departureCity = f.departure_city
        flight.arrivalCity = f.arrival_city
        flight.departureLat = f.departure_lat ?? 0
        flight.departureLon = f.departure_lon ?? 0
        flight.arrivalLat = f.arrival_lat ?? 0
        flight.arrivalLon = f.arrival_lon ?? 0
        flight.scheduledDeparture = scheduledDep
        flight.scheduledArrival = scheduledArr
        flight.estimatedArrival = DateHelpers.parseAPIDate(f.estimated_arrival)
        flight.statusRaw = FlightStatus.heal(rawValue: f.status, scheduledArrival: scheduledArr).rawValue
        flight.delayMinutes = f.delay_minutes
        flight.departureGate = f.departure_gate
        flight.arrivalGate = f.arrival_gate
        flight.baggageClaim = f.baggage_claim
        flight.liveLat = f.live_lat
        flight.liveLon = f.live_lon
        return flight
    }

    /// Both the list (.task) and the map (tab switch) call this — the
    /// throttle collapses those into one fetch.
    func refresh() async {
        guard ArcSupabase.shared.isSignedIn else { friends = []; pending = []; return }
        // Profile not loaded yet (cold launch, bootstrap still running):
        // bail WITHOUT arming the throttle, so the bootstrap's own refresh
        // isn't swallowed a moment later.
        guard ArcSupabase.shared.currentUser != nil else { return }
        if isLoading { return }
        if let last = lastRefreshAt, Date.now.timeIntervalSince(last) < 20 { return }
        lastRefreshAt = .now
        isLoading = true
        lastError = nil
        do {
            let supabase = ArcSupabase.shared
            let myId = supabase.currentUser?.id
            let friendships = try await supabase.getFriends()

            var entries: [FriendEntry] = []
            var profileById: [String: ArcSupabase.ArcUser] = [:]
            for f in friendships {
                let friendId = f.requester_id == myId ? f.addressee_id : f.requester_id
                if profileById[friendId] == nil,
                   let profile = try? await supabase.getProfile(userId: friendId) {
                    profileById[friendId] = profile
                }
                if let profile = profileById[friendId] {
                    entries.append(FriendEntry(friendshipId: f.id, user: profile, flights: []))
                }
            }

            // ONE query for every friend's flights, then bucket locally.
            let allFlights = try await supabase.friendsFlights(userIds: entries.map(\.id))
            var byUser: [String: [ArcSupabase.SharedFlight]] = [:]
            for flight in allFlights { byUser[flight.user_id, default: []].append(flight) }
            for i in entries.indices { entries[i].flights = byUser[entries[i].id] ?? [] }
            friends = entries

            let requests = try await supabase.getPendingRequests()
            var loadedPending: [(ArcSupabase.Friendship, ArcSupabase.ArcUser)] = []
            for r in requests {
                if let profile = try? await supabase.getProfile(userId: r.requester_id) {
                    loadedPending.append((r, profile))
                }
            }
            pending = loadedPending.map { (friendship: $0.0, user: $0.1) }

            // Diff against the persisted baseline: friend notifications +
            // friend Live Activities ride every refresh, foreground or BGTask.
            await FriendAlerts.process(entries: friends)
        } catch {
            lastError = "Couldn't load friends: \(error.localizedDescription)"
        }
        isLoading = false
    }
}

// MARK: - Pure helpers (unit-tested)

/// Clock math over `shared_flights` rows. Rows carry ISO strings and a
/// possibly stale status — same healing rules as the rest of the app: the
/// clock wins over what the status claims.
enum FriendFlightMath {
    static func departure(_ f: ArcSupabase.SharedFlight) -> Date? {
        DateHelpers.parseAPIDate(f.scheduled_departure)
            .map { $0.addingTimeInterval(Double(f.delay_minutes) * 60) }
    }

    static func arrival(_ f: ArcSupabase.SharedFlight) -> Date? {
        DateHelpers.parseAPIDate(f.estimated_arrival)
            ?? DateHelpers.parseAPIDate(f.scheduled_arrival)
                .map { $0.addingTimeInterval(Double(f.delay_minutes) * 60) }
    }

    /// Is this flight in the air right now (clock-healed)?
    static func isAirborne(_ f: ArcSupabase.SharedFlight, at now: Date = .now) -> Bool {
        if f.status == "cancelled" { return false }
        guard let dep = departure(f), let arr = arrival(f) else { return f.status == "active" }
        if f.status == "landed" { return false }
        return now >= dep && now <= arr
    }

    /// 0…1 along the route, derived from times — moves smoothly even though
    /// the row only updates when the friend's device polls.
    static func progress(_ f: ArcSupabase.SharedFlight, at now: Date = .now) -> Double {
        if f.status == "landed" { return 1 }
        guard let dep = departure(f), let arr = arrival(f), arr > dep else { return f.progress }
        return min(1, max(0, now.timeIntervalSince(dep) / arr.timeIntervalSince(dep)))
    }

    /// Coarse lifecycle bucket — the unit friend alerts diff on.
    enum Phase: String { case upcoming, airborne, landed }
    static func phase(_ f: ArcSupabase.SharedFlight, at now: Date = .now) -> Phase {
        if f.status == "cancelled" { return .upcoming }
        if f.status == "landed" { return .landed }
        guard let dep = departure(f), let arr = arrival(f) else {
            return f.status == "active" ? .airborne : .upcoming
        }
        if now < dep { return .upcoming }
        if now <= arr { return .airborne }
        return .landed
    }

    /// The flight a friend's row/bubble should show. Priority: airborne now →
    /// next upcoming (within 36h — a trip next month isn't "news") → landed
    /// within the last 24h → nothing.
    static func spotlight(from flights: [ArcSupabase.SharedFlight],
                          at now: Date = .now) -> ArcSupabase.SharedFlight? {
        let valid = flights.filter { $0.status != "cancelled" }
        if let flying = valid.first(where: { isAirborne($0, at: now) }) { return flying }
        let upcoming = valid
            .compactMap { f in departure(f).map { (f, $0) } }
            .filter { $0.1 > now && $0.1 < now.addingTimeInterval(36 * 3600) }
            .min { $0.1 < $1.1 }
        if let upcoming { return upcoming.0 }
        let recentlyLanded = valid
            .compactMap { f in arrival(f).map { (f, $0) } }
            .filter { $0.1 <= now && $0.1 > now.addingTimeInterval(-24 * 3600) }
            .max { $0.1 < $1.1 }
        return recentlyLanded?.0
    }

    /// Status-chip text + severity for a friend row, Flighty-style.
    enum ChipKind { case landed, delayed, inFlight, countdown, boarding }
    static func chip(for f: ArcSupabase.SharedFlight,
                     at now: Date = .now) -> (text: String, kind: ChipKind) {
        if isAirborne(f, at: now) {
            if let arr = arrival(f) {
                let mins = max(0, Int(arr.timeIntervalSince(now) / 60))
                return ("LANDS IN \(hm(mins))", .inFlight)
            }
            return ("IN FLIGHT", .inFlight)
        }
        if f.status == "landed" || (arrival(f).map { $0 <= now } ?? false) {
            return ("LANDED", .landed)
        }
        if f.delay_minutes > 0 { return ("DELAYED", .delayed) }
        if f.status == "boarding" { return ("BOARDING", .boarding) }
        if let dep = departure(f), dep > now {
            let mins = Int(dep.timeIntervalSince(now) / 60)
            return ("IN \(hm(mins))", .countdown)
        }
        return ("ON TIME", .countdown)
    }

    static func hm(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)H \(minutes % 60)M" : "\(minutes)M"
    }

    /// "2h 10m" / "45m" — lowercase variant for prose lines ("Landing in …").
    static func hmLower(_ minutes: Int) -> String {
        let m = max(0, minutes)
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    /// A shared flight's time rendered local to its airport ("09:15" at ZRH),
    /// matching how every other screen shows flight times.
    static func localHHmm(_ date: Date?, at iata: String) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = ReferenceData.shared.timezone(iata) ?? .current
        return formatter.string(from: date)
    }
}
