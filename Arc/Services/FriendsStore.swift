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

    /// Each friend's spotlight flight as a map overlay — the bubble on the
    /// globe. Airborne friends sit along their route by clock progress (or at
    /// their live ADS-B fix); upcoming/landed friends sit at the airport.
    struct FriendMapOverlay: Identifiable {
        let id: String
        let name: String
        let dep: CLLocationCoordinate2D
        let arr: CLLocationCoordinate2D
        let progress: Double
        let live: CLLocationCoordinate2D?
        let airborne: Bool
    }

    var mapOverlays: [FriendMapOverlay] {
        friends.compactMap { entry in
            guard let f = entry.spotlight,
                  let dlat = f.departure_lat, let dlon = f.departure_lon,
                  let alat = f.arrival_lat, let alon = f.arrival_lon,
                  dlat != 0 || dlon != 0
            else { return nil }
            return FriendMapOverlay(
                id: f.id,
                name: entry.user.display_name,
                dep: .init(latitude: dlat, longitude: dlon),
                arr: .init(latitude: alat, longitude: alon),
                progress: FriendFlightMath.progress(f),
                live: (f.live_lat != nil && f.live_lon != nil)
                    ? .init(latitude: f.live_lat!, longitude: f.live_lon!) : nil,
                airborne: FriendFlightMath.isAirborne(f))
        }
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

    private static func hm(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)H \(minutes % 60)M" : "\(minutes)M"
    }
}
