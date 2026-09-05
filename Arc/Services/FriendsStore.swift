import Foundation
import SwiftUI
import SwiftData
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
    /// False until the first refresh has actually completed. On a cold launch
    /// the session token is present but the profile isn't loaded yet, so a
    /// refresh bails early — and "No friends yet" was shown to people with
    /// friends for the whole bootstrap round-trip.
    var hasLoadedOnce = false
    private var lastRefreshAt: Date?

    // MARK: Trip invites ("travelling with")

    /// A friend has added a trip for the two of you and is waiting for an
    /// answer. Rendered pinned above My Trips; Accept materialises the journey
    /// as the user's own flight, Decline just clears it.
    struct TripInviteItem: Identifiable {
        let invite: ArcSupabase.TripInvite
        let sender: ArcSupabase.ArcUser
        var id: String { invite.id }
    }
    var tripInvites: [TripInviteItem] = []

    /// Invites THIS user sent, open or accepted — so a trip's detail can show
    /// "Invited · Peter" until he takes it up.
    var sentTripInvites: [ArcSupabase.TripInvite] = []

    /// Friends invited onto `flight` who haven't answered yet.
    func pendingCompanions(for flight: Flight) -> [ArcSupabase.ArcUser] {
        let key = Self.journeyKey(flight.flightNumber, flight.scheduledDeparture)
        return sentTripInvites
            .filter { $0.status == "pending" && Self.journeyKey($0.flight_number, DateHelpers.parseAPIDate($0.scheduled_departure)) == key }
            .compactMap { invite in friends.first { $0.id == invite.to_user }?.user }
    }

    /// Everyone already invited onto `flight`, answered or not — the picker
    /// pre-ticks these so the sender doesn't invite Peter twice.
    func invitedIds(for flight: Flight) -> [String] {
        let key = Self.journeyKey(flight.flightNumber, flight.scheduledDeparture)
        return sentTripInvites
            .filter { Self.journeyKey($0.flight_number, DateHelpers.parseAPIDate($0.scheduled_departure)) == key }
            .map(\.to_user)
    }

    /// The natural key of a journey: number + departure to the minute. Same
    /// tolerance `companions(for:)` needs — ISO strings lose sub-second
    /// precision on the way through PostgREST.
    static func journeyKey(_ number: String, _ departure: Date?) -> String {
        let n = number.replacingOccurrences(of: " ", with: "").uppercased()
        let t = departure.map { Int($0.timeIntervalSince1970 / 60) } ?? -1
        return "\(n)|\(t)"
    }

    /// Right after sending, so the detail screen shows "Invited · Peter"
    /// without waiting out the refresh throttle.
    func refreshSentTripInvites() async {
        guard ArcSupabase.shared.currentUser != nil else { return }
        if let sent = try? await ArcSupabase.shared.sentTripInvites() { sentTripInvites = sent }
    }

    /// Accept: the journey becomes the user's own flight, saved, tracked and
    /// mirrored like any other add. Runs the network answer AFTER the local
    /// save so a dead connection can never lose the trip — worst case the
    /// invite is answered again on the next refresh via `reconcile`.
    ///
    /// Returns the materialised trip, so an accept gets the same beat an add
    /// does: the row appears and the map draws its route on. nil means nothing
    /// was materialised — a duplicate tap, or a save that failed and said so.
    func accept(_ item: TripInviteItem, into context: ModelContext) async -> Flight? {
        // Two fast taps enqueue two Tasks with the same item — only the one
        // that still finds the invite listed may materialise it.
        guard tripInvites.contains(where: { $0.id == item.id }) else { return nil }
        let flight = item.invite.flight.materialize()
        context.insert(flight)
        do { try context.save() } catch {
            context.delete(flight)
            lastError = "Couldn't save this trip: \(error.localizedDescription)"
            return nil
        }
        withAnimation { tripInvites.removeAll { $0.id == item.id } }
        if flight.isUpcoming { ArcNotifications.scheduleDepartureReminder(for: flight) }
        Task {
            try? await ArcSupabase.shared.upsertUserFlight(flight)
            _ = try? await ArcSupabase.shared.shareFlight(flight)
            try? await ArcSupabase.shared.respondToTripInvite(id: item.id, accept: true)
        }
        return flight
    }

    func decline(_ item: TripInviteItem) {
        withAnimation { tripInvites.removeAll { $0.id == item.id } }
        // Remembered durably BEFORE the network call: the server answer is
        // best-effort, and a failed decline used to resurrect the card on
        // every refresh — dismissed again, failed again, forever. The refresh
        // path re-answers any remembered decline the server still returns.
        var declined = Set(UserDefaults.standard.stringArray(forKey: Self.declinedInvitesKey) ?? [])
        declined.insert(item.id)
        UserDefaults.standard.set(Array(declined), forKey: Self.declinedInvitesKey)
        Task { try? await ArcSupabase.shared.respondToTripInvite(id: item.id, accept: false) }
    }

    private static let declinedInvitesKey = "tripInvites.declined"

    // MARK: - Unsent trip invites (durable retry)

    /// Companion invites the user chose that never reached the server —
    /// keyed by the trip's natural key and persisted, because both send
    /// sites (the add sheet and the detail picker) dismiss before the
    /// network answers, so there is nowhere to report a failure and nothing
    /// the user could do with one. The picker's promise — "they'll get this
    /// trip offered in their own list" — is kept by retrying instead.
    private static let unsentInvitesKey = "tripInvites.unsent"
    private var retryingUnsentInvites = false

    private var unsentInvites: [String: [String]] {
        get { (UserDefaults.standard.dictionary(forKey: Self.unsentInvitesKey) as? [String: [String]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.unsentInvitesKey) }
    }

    func noteUnsentInvites(for flight: Flight, ids: [String]) {
        guard !ids.isEmpty else { return }
        let key = Self.journeyKey(flight.flightNumber, flight.scheduledDeparture)
        var all = unsentInvites
        all[key] = Array(Set((all[key] ?? []) + ids))
        unsentInvites = all
    }

    /// Retry every queued invite whose flight still exists locally. Rides
    /// reconcileTripInvites' cadence: flight-list changes and invite loads.
    func retryUnsentInvites(with userFlights: [Flight]) {
        guard !retryingUnsentInvites, !unsentInvites.isEmpty else { return }
        retryingUnsentInvites = true
        Task {
            defer { retryingUnsentInvites = false }
            for (key, ids) in unsentInvites {
                guard let flight = userFlights.first(where: {
                    Self.journeyKey($0.flightNumber, $0.scheduledDeparture) == key
                }), !flight.isDeleted else {
                    // The trip is gone; so is the promise.
                    var pruned = unsentInvites
                    pruned.removeValue(forKey: key)
                    unsentInvites = pruned
                    continue
                }
                do {
                    _ = try? await ArcSupabase.shared.shareFlight(flight)
                    try await ArcSupabase.shared.sendTripInvites(flight, to: ids)
                    var done = unsentInvites
                    done.removeValue(forKey: key)
                    unsentInvites = done
                    await refreshSentTripInvites()
                } catch {
                    // Still queued; the next reconcile pass retries.
                }
            }
        }
    }

    /// Invites for a journey the user ALREADY has (they added the same
    /// flight themselves) are answered silently — the companions card just
    /// gains the sender. Called with the local flights whenever either side
    /// changes; the store itself has no model context.
    func reconcileTripInvites(with userFlights: [Flight]) {
        // Same cadence, other direction: invites WE owe that never landed.
        retryUnsentInvites(with: userFlights)
        guard !tripInvites.isEmpty else { return }
        let mine = Set(userFlights.map { Self.journeyKey($0.flightNumber, $0.scheduledDeparture) })
        let already = tripInvites.filter { item in
            mine.contains(Self.journeyKey(item.invite.flight_number,
                                          DateHelpers.parseAPIDate(item.invite.scheduled_departure)))
        }
        guard !already.isEmpty else { return }
        tripInvites.removeAll { item in already.contains { $0.id == item.id } }
        for item in already {
            Task { try? await ArcSupabase.shared.respondToTripInvite(id: item.id, accept: true) }
        }
    }

    /// Announce invites the user hasn't been told about yet — against a
    /// PERSISTED set, so a background refresh and the next cold launch don't
    /// both ring for the same one.
    private func announceNewTripInvites(_ items: [TripInviteItem]) {
        let key = "tripInvites.announced"
        var announced = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        for item in items where !announced.contains(item.id) {
            announced.insert(item.id)
            ArcNotifications.notifyTripInvite(item)
        }
        // Prune answered/withdrawn ids so the set can't grow forever.
        announced.formIntersection(items.map(\.id))
        UserDefaults.standard.set(Array(announced), forKey: key)
    }

    struct AirportOverlap: Identifiable, Equatable {
        let id = UUID()
        let friend: ArcSupabase.ArcUser
        let airportIATA: String
        let timeWindow: String
        let isToday: Bool
        /// The user's own flight this overlap was detected against — the tap
        /// destination for the notification. Without it, "Anna is at ZRH too"
        /// opened the app to whatever was last on screen.
        let myFlightId: UUID

        static func == (a: Self, b: Self) -> Bool {
            a.friend.id == b.friend.id && a.airportIATA == b.airportIATA
        }
    }
    var activeOverlaps: [AirportOverlap] = []

    /// Detect friends flying on the exact same flight number and date.
    func companions(for flight: Flight) -> [(user: ArcSupabase.ArcUser, seat: String?)] {
        let myNum = flight.flightNumber.replacingOccurrences(of: " ", with: "").uppercased()
        guard !myNum.isEmpty else { return [] }
        var matches: [(user: ArcSupabase.ArcUser, seat: String?)] = []
        for entry in friends {
            for f in entry.flights where f.status != "cancelled" {
                let fNum = f.flight_number.replacingOccurrences(of: " ", with: "").uppercased()
                if fNum == myNum {
                    if let dep = FriendFlightMath.departure(f),
                       abs(dep.timeIntervalSince(flight.scheduledDeparture)) < 18 * 3600 {
                        matches.append((user: entry.user, seat: f.seat))
                        break
                    }
                }
            }
        }
        return matches
    }

    /// Match user's active/upcoming flights against friends' flights at the same airport within 3 hours.
    func updateAirportOverlaps(with userFlights: [Flight]) {
        let now = Date.now
        var found: [AirportOverlap] = []
        let myUpcoming = userFlights.filter { $0.isUpcoming || $0.isActive || $0.isRecentlyLanded }
        
        for myFlight in myUpcoming {
            let myDepTime = myFlight.effectiveDeparture
            let myArrTime = myFlight.effectiveArrival
            
            for entry in friends {
                for friendFlight in entry.flights where friendFlight.status != "cancelled" {
                    // check departure or arrival IATA match
                    let friendDep = FriendFlightMath.departure(friendFlight) ?? now
                    let friendArr = FriendFlightMath.arrival(friendFlight) ?? friendDep.addingTimeInterval(2 * 3600)
                    
                    var matchIATA: String? = nil
                    var tStart: Date? = nil
                    var tEnd: Date? = nil
                    
                    // Match departure airport
                    if myFlight.departureIATA.uppercased() == friendFlight.departure_iata.uppercased(),
                       abs(myDepTime.timeIntervalSince(friendDep)) <= 3 * 3600,
                       myDepTime > now.addingTimeInterval(-6 * 3600) {
                        matchIATA = myFlight.departureIATA.uppercased()
                        tStart = min(myDepTime, friendDep).addingTimeInterval(-3600)
                        tEnd = max(myDepTime, friendDep)
                    }
                    // Match arrival / connection airport
                    else if myFlight.arrivalIATA.uppercased() == friendFlight.departure_iata.uppercased() ||
                            myFlight.departureIATA.uppercased() == friendFlight.arrival_iata.uppercased() ||
                            myFlight.arrivalIATA.uppercased() == friendFlight.arrival_iata.uppercased() {
                        let myT = myFlight.arrivalIATA.uppercased() == friendFlight.arrival_iata.uppercased() ? myArrTime : myDepTime
                        let fT = friendFlight.departure_iata.uppercased() == myFlight.arrivalIATA.uppercased() ? friendDep : friendArr
                        if abs(myT.timeIntervalSince(fT)) <= 3 * 3600, myT > now.addingTimeInterval(-6 * 3600) {
                            matchIATA = myFlight.arrivalIATA.uppercased() == friendFlight.departure_iata.uppercased() ? myFlight.arrivalIATA.uppercased() : friendFlight.arrival_iata.uppercased()
                            tStart = min(myT, fT).addingTimeInterval(-3600)
                            tEnd = max(myT, fT).addingTimeInterval(3600)
                        }
                    }
                    
                    if let airport = matchIATA, let s = tStart, let e = tEnd {
                        let fmt = DateFormatter()
                        fmt.dateFormat = "HH:mm"
                        let win = "\(fmt.string(from: s)) - \(fmt.string(from: e))"
                        let isToday = Calendar.current.isDateInToday(s)
                        let overlap = AirportOverlap(friend: entry.user, airportIATA: airport, timeWindow: win, isToday: isToday, myFlightId: myFlight.id)
                        if !found.contains(where: { $0 == overlap }) {
                            found.append(overlap)
                        }
                    }
                }
            }
        }
        // Announce only what's newly discovered — against a PERSISTED set,
        // not in-memory state: every cold launch started with empty memory,
        // so the same "Anna is at ZRH too" fired again on every app open.
        // Keys are pruned once their overlap ends, so a future rendezvous at
        // the same airport can announce again.
        let announcedKey = "friendOverlaps.announced"
        var announced = Set(UserDefaults.standard.stringArray(forKey: announcedKey) ?? [])
        for overlap in found {
            let key = "\(overlap.friend.id)|\(overlap.airportIATA)"
            if !announced.contains(key) {
                announced.insert(key)
                ArcNotifications.notifyAirportOverlap(overlap)
            }
        }
        // Only prune on a real pass — a refresh that ran before the friends
        // list loaded would otherwise wipe the memory and re-announce
        // everything on the next one.
        if !friends.isEmpty {
            announced.formIntersection(found.map { "\($0.friend.id)|\($0.airportIATA)" })
        }
        UserDefaults.standard.set(Array(announced), forKey: announcedKey)
        self.activeOverlaps = found
    }

    /// Invite code from an arc://friend/<code> link, waiting for a session.
    /// (Opening a link can precede profile setup — the code parks here until
    /// there's a signed-in user to redeem it with.)
    var pendingInviteCode: String?

    /// A friend's flight a notification tap asked for, parked until the feed
    /// has actually loaded. Same reason as `pendingInviteCode`: a cold launch
    /// routes long before there is anything to route TO.
    var pendingFlightId: String?
    /// Set after a successful redeem — drives the "You and X are now sharing
    /// flights" confirmation.
    var justRedeemedFriend: ArcSupabase.ArcUser?

    func redeemPendingIfPossible() async {
        guard let code = pendingInviteCode,
              ArcSupabase.shared.currentUser != nil else { return }
        do {
            if let friend = try await ArcSupabase.shared.redeemInvite(code: code) {
                pendingInviteCode = nil
                justRedeemedFriend = friend
                lastRefreshAt = nil   // force the next refresh through the throttle
                await refresh()
            } else {
                // The server answered: unknown, expired, or the user's own
                // code. No retry can fix that — say so once and let it go.
                pendingInviteCode = nil
                lastError = "That friend invite isn't valid anymore — ask for a fresh link."
            }
        } catch {
            // The attempt never reached an answer. The code used to be
            // cleared BEFORE the attempt, so a link tapped on flaky wifi
            // switched to the Friends tab and silently did nothing, forever.
            // Keep it parked — the next refresh retries — and say why.
            lastError = "Couldn't redeem the friend invite — check your connection and try again."
        }
    }

    /// Selected filter from the Friends' Flights list — the map mirrors it, so
    /// filtering to Anna also filters the globe to Anna. A set rather than one
    /// id because a group filter selects several people at once; nil means no
    /// filter at all.
    var mapFilterIds: Set<String>?

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
        /// The leg's vehicle glyph — a friend AT SEA gets a ferry on their
        /// chip, not an airplane.
        let symbol: String
        /// And its route grammar: a sailing draws as a dotted teal rhumb line,
        /// not a flight's arc.
        let mode: TripMode
    }

    /// Bumped once a minute while the Friends tab is visible — SwiftUI only
    /// re-derives overlay positions on render, so without this an airborne
    /// bubble would sit still while the user just watches the map.
    var clockTick = 0

    var mapOverlays: [FriendMapOverlay] {
        _ = clockTick   // observation hook: the minute tick re-derives positions
        var items = feed
        if let ids = mapFilterIds { items = items.filter { ids.contains($0.user.id) } }
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
            let liveFresh = f.lastKnownAt
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
                chipKind: chip.kind,
                symbol: f.tripMode.symbol,
                mode: f.tripMode)
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
    /// flights landed in the last 30 minutes. Older landings live in
    /// `pastFeed` — same grace period a user's own flight gets in My Flights
    /// before moving to Passport.
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
                // Bucket 0 is "happening now", and that starts at the gate,
                // not at wheels-up: a friend whose aircraft has pushed back
                // and is queueing for the runway used to qualify only because
                // isAirborne lied about them. With honest phases they would
                // have fallen through every bucket and disappeared from the
                // feed for the whole taxi — the exact minutes people watch.
                if FriendFlightMath.isUnderway(f, at: now), let arr = FriendFlightMath.arrival(f) {
                    ranked.append((item, 0, arr.timeIntervalSince1970))
                } else if let dep = FriendFlightMath.departure(f), dep > now {
                    ranked.append((item, 1, dep.timeIntervalSince1970))
                } else if let arr = FriendFlightMath.arrival(f), arr <= now,
                          arr > now.addingTimeInterval(-FriendFlightMath.landedGrace) {
                    ranked.append((item, 2, -arr.timeIntervalSince1970))
                }
            }
        }
        return ranked
            .sorted { ($0.bucket, $0.order) < ($1.bucket, $1.order) }
            .map(\.item)
    }

    /// Flights whose 30-minute post-landing grace has expired — the collapsed
    /// "Past Flights" section at the bottom of the friends list. Two weeks is
    /// plenty: this is "how was the trip?", not an archive.
    var pastFeed: [FeedItem] { pastFeed(at: .now) }

    func pastFeed(at now: Date) -> [FeedItem] {
        var out: [(item: FeedItem, arr: Date)] = []
        for entry in friends {
            for f in entry.flights where f.status != "cancelled" {
                guard !FriendFlightMath.isUnderway(f, at: now),
                      let arr = FriendFlightMath.arrival(f),
                      arr <= now.addingTimeInterval(-FriendFlightMath.landedGrace),
                      arr > now.addingTimeInterval(-14 * 24 * 3600)
                else { continue }
                out.append((FeedItem(user: entry.user, flight: f), arr))
            }
        }
        return out.sorted { $0.arr > $1.arr }.map(\.item)
    }

    /// Ask the server to re-check this friend's flight against the provider,
    /// then re-read the feed.
    ///
    /// The friend path used to make no network call at all: it rendered the
    /// mirrored `shared_flights` row and nothing else, so a friend's flight was
    /// only ever as fresh as the last cron tick or the traveller's own phone —
    /// even though the one device that is certainly awake and certainly
    /// interested is the one doing the looking. Cheap: the Worker ignores a row
    /// it checked in the last minute, and the fetch underneath rides the same
    /// shared leg cache, so ten friends opening the same flight cost one call.
    ///
    /// `onscreen` is the Flight the detail sheet is currently holding, if one
    /// is open. The sheet is built from a snapshot of the row taken before the
    /// ask, so refreshing the store alone left it showing the figure it opened
    /// with — the "Updated 16h ago" this call exists to clear — until it was
    /// closed and opened again.
    func refreshLive(_ item: FeedItem, updating onscreen: Flight? = nil) async {
        guard shouldAskServer(item, at: .now) else { return }
        guard await FlightAPIClient.shared.refreshFriendFlight(id: item.flight.id) else { return }
        await refresh(force: true)
        guard let onscreen,
              let fresh = feed.first(where: { $0.flight.id == item.flight.id }) else { return }
        apply(fresh, to: onscreen)
    }

    /// A pull-to-refresh: re-read the rows, then have the server re-check the
    /// few legs where the answer can actually have moved. Capped and ordered by
    /// imminence — a taxiing aircraft matters more than one leaving tomorrow,
    /// and a feed of twenty friends must not become twenty round-trips.
    func refreshLiveVisible(limit: Int = 3) async {
        await refresh(force: true)
        let now = Date.now
        let due = feed
            .filter { shouldAskServer($0, at: now) }
            .sorted { a, b in
                let da = FriendFlightMath.departure(a.flight) ?? .distantFuture
                let db = FriendFlightMath.departure(b.flight) ?? .distantFuture
                return abs(da.timeIntervalSince(now)) < abs(db.timeIntervalSince(now))
            }
            .prefix(limit)
        guard !due.isEmpty else { return }
        var touched = false
        for item in due {
            if await FlightAPIClient.shared.refreshFriendFlight(id: item.flight.id) { touched = true }
        }
        if touched { await refresh(force: true) }
    }

    /// Whether asking the server about this leg can mean anything.
    ///
    /// Deliberately NOT the cron's thirty-hour window, which this used to
    /// borrow. That bound prices a background job: every shared row, every
    /// hour, for ever, whether or not a soul is looking. An open is the
    /// opposite — one row, one call, because a person asked for it — and the
    /// server already bounds it far better than a clock here can: the Worker
    /// ignores a row it consulted in the last minute, the fetch underneath
    /// rides the shared leg cache, and an empty answer is itself cached, so a
    /// flight the provider cannot answer for yet costs one call per ten
    /// minutes no matter how often it is opened.
    ///
    /// Borrowing the cron's bound meant a friend's flight three weeks out made
    /// no call at all and read "Updated 16h ago", climbing, with nothing in the
    /// system that would ever reset it. No horizon replaces it: any number
    /// would just move that bug to a flight booked further ahead.
    ///
    /// What genuinely bounds the ask stays: a provider that cannot answer for
    /// rail or sea, a cancellation, and a flight already finished.
    func shouldAskServer(_ item: FeedItem, at now: Date) -> Bool {
        let f = item.flight
        guard (f.mode ?? "air") == "air" else { return false }
        guard f.status != "cancelled" else { return false }
        guard let dep = FriendFlightMath.departure(f) else { return false }
        let arr = FriendFlightMath.arrival(f) ?? dep.addingTimeInterval(2 * 3600)
        return now < arr.addingTimeInterval(FriendFlightMath.landedGrace)
    }

    /// A display-only Flight model — NOT inserted into SwiftData — so a
    /// friend's flight opens the exact same detail screen as the user's own
    /// flights. Edits made there (seat, notes) simply don't persist, which
    /// is correct: it isn't your flight.
    func transientFlight(for item: FeedItem) -> Flight {
        let scheduledDep = DateHelpers.parseAPIDate(item.flight.scheduled_departure) ?? .now
        let flight = Flight(flightNumber: item.flight.flight_number, date: scheduledDep)
        apply(item, to: flight)
        return flight
    }

    /// Write a re-read row onto a Flight that is ALREADY on screen.
    ///
    /// Split out of `transientFlight` because the sheet is presented with
    /// `.sheet(item:)`, which is keyed on `Flight.id` — a fresh UUID per
    /// construction. Assigning a newly built Flight would therefore dismiss
    /// and re-present the sheet rather than update it. `Flight` is a reference
    /// type, so writing the new values onto the instance the sheet is already
    /// holding keeps that identity and lets observation do the rest.
    ///
    /// Without this, `refreshLive` updated the store and stopped: the row was
    /// current and the open sheet still showed the snapshot it was built from,
    /// which is precisely the "Updated 16h ago" the refresh exists to clear.
    func apply(_ item: FeedItem, to flight: Flight) {
        let f = item.flight
        let scheduledDep = DateHelpers.parseAPIDate(f.scheduled_departure) ?? .now
        let scheduledArr = DateHelpers.parseAPIDate(f.scheduled_arrival)
            ?? scheduledDep.addingTimeInterval(2 * 3600)
        flight.mode = f.tripMode
        flight.dataTier = f.tier
        flight.airline = f.airline
        // Only a flight number begins with an airline code. "BLUE STAR DELOS"
        // would yield "BL" and hang some unrelated carrier's logo on a ferry.
        flight.airlineICAO = f.tripMode == .air ? String(f.flight_number.prefix(2)) : ""
        // Each end's own zone. A friend's train from Berlin to Zürich crosses
        // one, and without these the times render in the reader's zone instead
        // of the station's — the same bug the ferry work exists to prevent.
        // IATA fallback when the shared row predates departure_tz/arrival_tz:
        // a friend Activity with nil zones printed Lisbon's arrival in the
        // viewer's CEST clock, which is the other half of the 1h jump.
        flight.departureTZID = f.departure_tz
            ?? (f.tripMode == .air ? ReferenceData.shared.timezone(f.departure_iata)?.identifier : nil)
        flight.arrivalTZID = f.arrival_tz
            ?? (f.tripMode == .air ? ReferenceData.shared.timezone(f.arrival_iata)?.identifier : nil)
        flight.vesselName = f.vessel_name
        flight.operatorLogoURL = f.operator_logo_url
        flight.disruptionNote = f.disruption_note
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
        // A reported take-off/landing is the difference between "Departed
        // 15m ago" and "15m past schedule" — the reader must hedge exactly
        // where the friend's own device hedges.
        flight.actualDeparture = DateHelpers.parseAPIDate(f.actual_departure)
        flight.actualArrival = DateHelpers.parseAPIDate(f.actual_arrival)
        flight.statusRaw = FlightStatus.heal(rawValue: f.status, scheduledArrival: scheduledArr).rawValue
        flight.delayMinutes = f.delay_minutes
        flight.departureGate = f.departure_gate
        flight.arrivalGate = f.arrival_gate
        flight.baggageClaim = f.baggage_claim
        flight.liveLat = f.live_lat
        flight.liveLon = f.live_lon
        // The row IS this flight's last refresh. `lastKnownAt`, not
        // `updated_at`: that one only moves when a FIELD CHANGES, so a flight
        // that was simply stable — cruising, on time, gates already known —
        // read as untouched for as long as it stayed stable. The screen said
        // "Updated 9h ago" about a row the cron had verified a minute earlier,
        // and never reached the ten-minute window in which it says "Live".
        flight.lastStatusUpdate = f.lastKnownAt
        if f.live_lat != nil || f.live_lon != nil {
            flight.liveUpdatedAt = f.lastKnownAt
        }
        // Same clock-healing the feed chip and map bubble already apply
        // (`FriendFlightMath.isAirborne`): the row carries the SOURCE's
        // status, which lags the clock, and the detail screen must not
        // contradict the chip that opened it ("LANDS IN 1H" over a sheet
        // saying "Departure not yet confirmed"). actualDeparture stays nil,
        // so the detail hedges ("Departing", "past schedule") exactly like
        // the friend's own device until a real departure is reported.
        // The evidence itself crosses, so the detail sheet reaches the same
        // conclusion as the chip that opened it rather than re-deriving one
        // from the clock.
        flight.estimatedTakeoff = DateHelpers.parseAPIDate(f.est_takeoff)
        flight.groundStateRaw = f.ground_state
        flight.groundObservedAt = DateHelpers.parseAPIDate(f.ground_observed_at)
        flight.taxiStartedAt = DateHelpers.parseAPIDate(f.taxi_started_at)
        flight.aircraftRegistration = f.aircraft_registration
        flight.aircraftICAO24 = f.aircraft_icao24
        if flight.isUpcoming, FriendFlightMath.isAirborne(f) {
            flight.statusRaw = FlightStatus.active.rawValue
        }
    }

    /// Both the list (.task) and the map (tab switch) call this — the
    /// throttle collapses those into one fetch.
    /// `force` bypasses the 20-second throttle. Every mutation's follow-up
    /// (redeem, accept request, remove friend, pull-to-refresh) must — the
    /// throttle is for the tab-open/map double-fire, and it was silently
    /// swallowing "show me what I just changed".
    func refresh(force: Bool = false) async {
        guard ArcSupabase.shared.isSignedIn else {
            friends = []; pending = []; sentTripInvites = []
            if !DemoSeed.isTripInviteRequested { tripInvites = [] }
            return
        }
        // Profile not loaded yet. A cold launch races the bootstrap — but a
        // bootstrap that FAILED (offline at launch) never retried, and this
        // guard then starved every friends surface for the life of the
        // process: signed in, spinner up, nothing loading, nothing said.
        // Retry the session; only when the retry also fails is there
        // something worth telling the user — and the spinner is released
        // (hasLoadedOnce is what the view keys "stop spinning" on), still
        // without arming the throttle, so pull-to-refresh genuinely retries.
        if ArcSupabase.shared.currentUser == nil {
            await ArcSupabase.shared.ensureProfileLoaded()
        }
        guard ArcSupabase.shared.currentUser != nil else {
            lastError = "Couldn't reach the server to load your friends. Pull to refresh to try again."
            hasLoadedOnce = true
            return
        }
        // An invite link parked before the session was ready redeems on the
        // next refresh instead of never. (Safe against recursion: a
        // successful redeem clears the code before its own refresh runs.)
        if pendingInviteCode != nil { await redeemPendingIfPossible() }
        if isLoading { return }
        if !force, let last = lastRefreshAt, Date.now.timeIntervalSince(last) < 20 { return }
        lastRefreshAt = .now
        isLoading = true
        lastError = nil
        do {
            let supabase = ArcSupabase.shared
            let myId = supabase.currentUser?.id
            let friendships = try await supabase.getFriends()

            var entries: [FriendEntry] = []
            var profileById: [String: ArcSupabase.ArcUser] = [:]
            var seenFriendIds = Set<String>()
            for f in friendships {
                let friendId = f.requester_id == myId ? f.addressee_id : f.requester_id
                // The friendship constraint is DIRECTIONAL — (A,B) and (B,A)
                // can both exist when two people invite each other. One entry
                // per person, or every keyed-by-id consumer downstream breaks
                // (Dictionary(uniqueKeysWithValues:) traps on duplicates).
                guard seenFriendIds.insert(friendId).inserted else { continue }
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

            // Trip invites, both directions. Senders are friends (RLS insists
            // at insert time), so their profiles are already in hand; the
            // fallback fetch covers someone unfriended since they invited.
            // An invite for a trip that already departed can't be joined any
            // more; answer it silently instead of pinning a dead card on top.
            let all = try await supabase.pendingTripInvites()
            let (incoming, stale) = all.reduce(into: ([ArcSupabase.TripInvite](), [ArcSupabase.TripInvite]())) { acc, invite in
                let dep = DateHelpers.parseAPIDate(invite.scheduled_departure) ?? .distantFuture
                if dep > Date.now.addingTimeInterval(-60 * 60) { acc.0.append(invite) } else { acc.1.append(invite) }
            }
            for invite in stale {
                Task { try? await supabase.respondToTripInvite(id: invite.id, accept: false) }
            }
            var items: [TripInviteItem] = []
            for invite in incoming {
                var sender = profileById[invite.from_user]
                if sender == nil {
                    sender = try? await supabase.getProfile(userId: invite.from_user)
                    if let sender { profileById[invite.from_user] = sender }
                }
                if let sender { items.append(TripInviteItem(invite: invite, sender: sender)) }
            }
            // Declines are remembered locally (see `decline`): an invite the
            // user already dismissed must neither reappear nor re-announce,
            // however many times the decline call itself fails — and each
            // sighting re-answers it until the server finally agrees. Ids the
            // server stopped returning are settled and pruned.
            let declined = Set(UserDefaults.standard.stringArray(forKey: Self.declinedInvitesKey) ?? [])
            for item in items where declined.contains(item.id) {
                Task { try? await supabase.respondToTripInvite(id: item.id, accept: false) }
            }
            let fresh = items.filter { !declined.contains($0.id) }
            UserDefaults.standard.set(Array(declined.intersection(items.map(\.id))),
                                      forKey: Self.declinedInvitesKey)
            if !DemoSeed.isTripInviteRequested { tripInvites = fresh }   // simulator seed survives
            announceNewTripInvites(fresh)
            sentTripInvites = (try? await supabase.sentTripInvites()) ?? sentTripInvites

            // Diff against the persisted baseline: friend notifications +
            // friend Live Activities ride every refresh, foreground or BGTask.
            await FriendAlerts.process(entries: friends)
            hasLoadedOnce = true
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
    /// How long a landed flight stays "live" (feed + map bubble) before
    /// retiring to Past Flights — mirrors My Flights' 30-minute grace.
    static let landedGrace: TimeInterval = 30 * 60

    static func departure(_ f: ArcSupabase.SharedFlight) -> Date? {
        DateHelpers.parseAPIDate(f.scheduled_departure)
            .map { $0.addingTimeInterval(Double(f.delay_minutes) * 60) }
    }

    static func arrival(_ f: ArcSupabase.SharedFlight) -> Date? {
        // The estimate is screened the way actual departures are: one at or
        // before the flight's own departure is another operation's timestamp
        // that reached this row (the old route-only leg match wrote
        // yesterday's arrival, and the row's carry-forward pinned it there)
        // — and trusted, it flipped a flight an hour from pushback into
        // "Arrival not yet confirmed". No flight arrives before it leaves.
        guard let scheduled = DateHelpers.parseAPIDate(f.scheduled_arrival) else { return nil }
        let screened = DateHelpers.parseAPIDate(f.estimated_arrival).flatMap { est -> Date? in
            est > (departure(f) ?? .distantPast) ? est : nil
        }
        return FlightClock.heroArrival(
            scheduled: scheduled, delayMinutes: f.delay_minutes,
            estimated: screened,
            actual: DateHelpers.parseAPIDate(f.actual_arrival))
    }

    /// Is this flight in the air right now (clock-healed)?
    /// The same question the traveller's own app answers, from the row a
    /// friend can see. Their phone is online while hers is in airplane mode,
    /// so this is where "Taxiing for 14m" comes from.
    static func evidence(_ f: ArcSupabase.SharedFlight) -> DepartureEvidence {
        DepartureEvidence(
            offBlock: departure(f) ?? .distantPast,
            estimatedTakeoff: DateHelpers.parseAPIDate(f.est_takeoff),
            actualDeparture: DateHelpers.parseAPIDate(f.actual_departure),
            groundState: f.ground_state,
            groundObservedAt: DateHelpers.parseAPIDate(f.ground_observed_at),
            taxiStartedAt: DateHelpers.parseAPIDate(f.taxi_started_at),
            lastSeenOnGround: nil,
            taxiPriorMinutes: DepartureEvidence.defaultTaxiPrior,
            isLiveCovered: f.tripMode == .air)
    }

    static func departurePhase(_ f: ArcSupabase.SharedFlight, at now: Date = .now) -> DeparturePhase {
        if f.status == "landed" || f.status == "diverted" { return .airborne }
        if f.status == "cancelled" { return .beforeDeparture }
        let phase = evidence(f).phase(at: now)
        if f.status == "active", phase == .beforeDeparture { return .airborne }
        return phase
    }

    /// How long the aircraft has been rolling, when someone has seen it.
    static func taxiElapsed(_ f: ArcSupabase.SharedFlight, at now: Date = .now) -> TimeInterval? {
        guard case .taxiing(let since) = departurePhase(f, at: now), let since else { return nil }
        return max(0, now.timeIntervalSince(since))
    }

    /// Under way in the sense the feed and the map care about: the journey
    /// has started and hasn't ended. Includes the taxi, which `isAirborne`
    /// deliberately does not — being off the ground is a stronger claim, and
    /// the surfaces that state it need the stronger one.
    static func isUnderway(_ f: ArcSupabase.SharedFlight, at now: Date = .now) -> Bool {
        if f.status == "cancelled" || f.status == "landed" { return false }
        guard let dep = departure(f), let arr = arrival(f) else { return f.status == "active" }
        return now >= dep && now <= arr
    }

    static func isAirborne(_ f: ArcSupabase.SharedFlight, at now: Date = .now) -> Bool {
        if f.status == "cancelled" { return false }
        guard departure(f) != nil, let arr = arrival(f) else { return f.status == "active" }
        if f.status == "landed" { return false }
        // Off the ground means off the ground: past the gate time is not the
        // same claim, and the difference is the taxi. The feed chip used to
        // say "IN FLIGHT" the instant the clock passed the schedule.
        return departurePhase(f, at: now).isOffTheGround && now <= arr
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
    /// The phase an ALERT may claim — witnessed, never inferred.
    ///
    /// The feed and map keep using `phase` below (clock-healed: a friend
    /// mid-flight with a quiet row still deserves a moving arc and an
    /// arrival countdown). A push notification is different in kind: it is
    /// words on a lock screen with no muted colour to hedge them, so "Anna
    /// is in the air" and "Anna landed" are only said once a source said
    /// them first — a reported departure, the provider calling the leg
    /// active, a fresh airborne sighting; landed only from the status. The
    /// alert baseline stores THIS phase, so a witness that arrives after
    /// the clock has already crossed still fires the transition, late
    /// rather than never.
    static func witnessedPhase(_ f: ArcSupabase.SharedFlight, at now: Date = .now) -> Phase {
        if f.status == "landed" { return .landed }
        if f.status == "active" || f.status == "diverted" { return .airborne }
        if evidence(f).phase(at: now) == .airborne { return .airborne }
        return .upcoming
    }

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
    /// within the last 30 minutes (then the bubble retires, matching the
    /// feed's grace period) → nothing.
    static func spotlight(from flights: [ArcSupabase.SharedFlight],
                          at now: Date = .now) -> ArcSupabase.SharedFlight? {
        let valid = flights.filter { $0.status != "cancelled" }
        if let flying = valid.first(where: { isUnderway($0, at: now) }) { return flying }
        let upcoming = valid
            .compactMap { f in departure(f).map { (f, $0) } }
            .filter { $0.1 > now && $0.1 < now.addingTimeInterval(36 * 3600) }
            .min { $0.1 < $1.1 }
        if let upcoming { return upcoming.0 }
        let recentlyLanded = valid
            .compactMap { f in arrival(f).map { (f, $0) } }
            .filter { $0.1 <= now && $0.1 > now.addingTimeInterval(-landedGrace) }
            .max { $0.1 < $1.1 }
        return recentlyLanded?.0
    }

    /// Status-chip text + severity for a friend row, Flighty-style.
    enum ChipKind { case landed, delayed, inFlight, countdown, boarding }
    static func chip(for f: ArcSupabase.SharedFlight,
                     at now: Date = .now) -> (text: String, kind: ChipKind) {
        if f.status == "cancelled" { return ("CANCELLED", .delayed) }
        if isAirborne(f, at: now) {
            if let arr = arrival(f) {
                let mins = max(0, Int(arr.timeIntervalSince(now) / 60))
                return ("LANDS IN \(hm(mins))", .inFlight)
            }
            return (f.tripMode.inTransitShort, .inFlight)
        }
        // "LANDED" is a fact only the source can state. Past the last
        // published arrival with no confirmation, the honest chip is DUE — a
        // friend holding over the airport must not be told to their family
        // as already on the ground.
        if f.status == "landed" { return (f.tripMode.arrivedShort, .landed) }
        if arrival(f).map({ $0 <= now }) ?? false { return ("DUE", .countdown) }
        // A delay is a report; a timetable-only leg has none to give.
        if f.delay_minutes > 0, f.tier.reportsPunctuality { return ("DELAYED", .delayed) }
        if f.status == "boarding" { return ("BOARDING", .boarding) }
        if let dep = departure(f), dep > now {
            let mins = Int(dep.timeIntervalSince(now) / 60)
            return ("IN \(hm(mins))", .countdown)
        }
        // Departure passed, nothing else known: say only that.
        return ("DEPARTED", .countdown)
    }

    /// Past a day, hours stop meaning anything ("IN 523H 14M") — roll to days.
    static func hm(_ minutes: Int) -> String {
        let m = max(0, minutes)
        if m >= 1440 {
            let d = m / 1440, h = (m % 1440) / 60
            return h > 0 ? "\(d)D \(h)H" : "\(d)D"
        }
        return m >= 60 ? "\(m / 60)H \(m % 60)M" : "\(m)M"
    }

    /// "2h 10m" / "45m" — lowercase variant for prose lines ("Landing in …").
    static func hmLower(_ minutes: Int) -> String {
        let m = max(0, minutes)
        if m >= 1440 {
            let d = m / 1440, h = (m % 1440) / 60
            return h > 0 ? "\(d)d \(h)h" : "\(d)d"
        }
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
