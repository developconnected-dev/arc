import Foundation
import AuthenticationServices
import Security

/// Lightweight Supabase client using REST API directly — no SDK dependency.
/// Handles auth (Sign in with Apple), profiles, flights, friendships, shared journeys, and watchers.
@MainActor
final class ArcSupabase: ObservableObject {
    static let shared = ArcSupabase()

    @Published var isSignedIn = false
    @Published var currentUser: ArcUser?

    private var accessToken: String? {
        didSet { TokenStore.write(accessToken, forKey: "arc_access_token") }
    }
    private var refreshToken: String? {
        didSet { TokenStore.write(refreshToken, forKey: "arc_refresh_token") }
    }

    private let baseURL: String
    private let anonKey: String

    struct ArcUser: Codable, Identifiable {
        let id: String
        var display_name: String
        var handle: String?
        var avatar_url: String?
        var home_airport: String?
        var nationality: String?   // ISO region code ("CH") — passport flag
    }

    init() {
        // Defaults match Settings' @AppStorage defaults — but @AppStorage's default
        // only applies within the view itself and never gets written to UserDefaults
        // until the user edits the field, so it's duplicated here directly to make
        // Supabase actually configured out of the box, not just "shown as configured
        // if you happen to open Settings first."
        self.baseURL = UserDefaults.standard.string(forKey: "supabase_url")
            ?? "https://qazngxdjwkenasxgdsif.supabase.co"
        self.anonKey = UserDefaults.standard.string(forKey: "supabase_anon_key")
            ?? "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InFhem5neGRqd2tlbmFzeGdkc2lmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQ1MzI3NzksImV4cCI6MjEwMDEwODc3OX0.pS3TCQM4v3cBnetUbazJtryj6BNHvbZ0bV_D5Fs4Wl8"
        self.accessToken = TokenStore.read(forKey: "arc_access_token")
        self.refreshToken = TokenStore.read(forKey: "arc_refresh_token")
        self.isSignedIn = accessToken != nil
        // Cold-launch session restore. Without this, a relaunched app was
        // "signed in" (token present) but currentUser stayed nil forever —
        // so every friends/sync call silently no-opped until the next
        // manual sign-in.
        if accessToken != nil {
            Task { await self.bootstrapSession() }
        }
    }

    /// Refresh the (≈1h) access token, load the profile, then wake the
    /// friends store — the order matters, everything downstream needs
    /// `currentUser`.
    private func bootstrapSession() async {
        await refreshSession()
        await loadProfile()
        if currentUser != nil {
            // A cold launch FROM an invite link races this bootstrap — the
            // parked code redeems here once the session is ready.
            await FriendsStore.shared.redeemPendingIfPossible()
            await FriendsStore.shared.refresh()
        }
    }

    /// Supabase access tokens expire after ~an hour; the refresh grant swaps
    /// the stored refresh token for a fresh pair. Reports whether it worked so
    /// a 401 can tell "just stale" apart from "genuinely signed out".
    @discardableResult
    private func refreshSession() async -> Bool {
        guard let token = refreshToken else { return false }
        guard let data = try? await post(path: "/auth/v1/token?grant_type=refresh_token",
                                         body: ["refresh_token": token], auth: false),
              let result = try? JSONDecoder().decode(AuthResponse.self, from: data)
        else { return false }
        accessToken = result.access_token
        refreshToken = result.refresh_token
        isSignedIn = true
        return true
    }

    var isConfigured: Bool { !baseURL.isEmpty && !anonKey.isEmpty }

    // MARK: - Auth

    /// The identity path: no email, no password, no verification step. GoTrue
    /// signup without credentials mints an anonymous user (enabled in the
    /// project's auth config); the profiles trigger picks the display name up
    /// from the signup metadata. The refresh token IS the identity, so it lives
    /// in the Keychain (see `TokenStore`) and survives a reinstall — otherwise
    /// every reinstall silently becomes a different person.
    func signInAnonymously(displayName: String, nationality: String?) async throws {
        let body: [String: Any] = ["data": ["full_name": displayName]]
        let data = try await post(path: "/auth/v1/signup", body: body, auth: false)
        let result = try decodeAuth(data)
        accessToken = result.access_token
        refreshToken = result.refresh_token
        isSignedIn = true
        await loadProfile()
        if let nationality {
            try? await updateProfile(nationality: nationality)
        }
    }

    func signInWithApple(idToken: String, nonce: String) async throws {
        let body: [String: Any] = [
            "provider": "apple",
            "id_token": idToken,
            "nonce": nonce
        ]
        let data = try await post(path: "/auth/v1/token?grant_type=id_token", body: body, auth: false)
        let result = try decodeAuth(data)
        accessToken = result.access_token
        refreshToken = result.refresh_token
        isSignedIn = true
        await loadProfile()
    }

    // MARK: - Email sign-in (works with zero extra setup — Supabase's built-in
    // email provider, unlike Apple which needs a Services ID + key configured
    // in both the Apple Developer portal and Supabase Auth settings)

    /// Sends a 6-digit sign-in code to `email`. `create_user: true` means a
    /// first-time email doubles as sign-up — there's no separate registration step.
    func requestEmailCode(email: String) async throws {
        let body: [String: Any] = ["email": email, "create_user": true]
        _ = try await post(path: "/auth/v1/otp", body: body, auth: false)
    }

    /// Exchanges the code from `requestEmailCode` for a session.
    func verifyEmailCode(email: String, code: String) async throws {
        let body: [String: Any] = ["email": email, "token": code, "type": "email"]
        let data = try await post(path: "/auth/v1/verify", body: body, auth: false)
        let result = try decodeAuth(data)
        accessToken = result.access_token
        refreshToken = result.refresh_token
        isSignedIn = true
        await loadProfile()
    }

    /// Supabase returns a 2xx with `{access_token, refresh_token, ...}` on
    /// success, or a non-2xx with `{error_description}` / `{msg}` on failure —
    /// surface that message instead of a generic decode error.
    private func decodeAuth(_ data: Data) throws -> AuthResponse {
        if let result = try? JSONDecoder().decode(AuthResponse.self, from: data) {
            return result
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let message = (obj["error_description"] as? String) ?? (obj["msg"] as? String) ?? (obj["error"] as? String)
            throw ArcError.server(message ?? "Sign-in failed.")
        }
        throw ArcError.server("Sign-in failed.")
    }

    func signOut() {
        accessToken = nil
        refreshToken = nil
        currentUser = nil
        isSignedIn = false
    }

    private func loadProfile() async {
        guard let token = accessToken else { return }
        do {
            // Decode user ID from JWT
            let userId = decodeJWTUserId(token)
            guard let uid = userId else { return }

            let data = try await get(path: "/rest/v1/profiles?id=eq.\(uid)&select=*")
            let profiles = try JSONDecoder().decode([ArcUser].self, from: data)
            currentUser = profiles.first
        } catch {}
    }

    func updateProfile(displayName: String? = nil, handle: String? = nil,
                       homeAirport: String? = nil, nationality: String? = nil) async throws {
        guard let uid = currentUser?.id else { return }
        var body: [String: Any] = [:]
        if let name = displayName { body["display_name"] = name }
        if let h = handle { body["handle"] = h }
        if let airport = homeAirport { body["home_airport"] = airport }
        if let nationality { body["nationality"] = nationality }

        _ = try await patch(path: "/rest/v1/profiles?id=eq.\(uid)", body: body)
        await loadProfile()
    }

    /// Sets or clears the avatar (a compact data: URL — Memoji sticker or
    /// photo). Separate from updateProfile so "clear" is expressible.
    func updateAvatar(dataURL: String?) async throws {
        guard let uid = currentUser?.id else { return }
        _ = try await patch(path: "/rest/v1/profiles?id=eq.\(uid)",
                            body: ["avatar_url": dataURL ?? NSNull()])
        await loadProfile()
    }

    // MARK: - Friend invites (capability links, Flighty-style)

    /// Mints a 48-hour invite link code. Anyone who opens the link and has
    /// (or sets up) the app becomes a friend — no requests, no approval step.
    func createFriendInvite() async throws -> String {
        guard let uid = currentUser?.id else { throw ArcError.notSignedIn }
        let code = generateShareCode()
        _ = try await post(path: "/rest/v1/friend_invites", body: ["code": code, "inviter": uid])
        return code
    }

    /// Redeems an invite code: validates it, then inserts an already-accepted
    /// friendship (invite links skip the request/approve dance on purpose).
    /// Returns the new friend's profile, or nil if the code is unknown,
    /// expired, or the user's own.
    func redeemInvite(code: String) async throws -> ArcUser? {
        guard let uid = currentUser?.id else { return nil }
        struct Row: Codable { let inviter: String; let expires_at: String? }
        let cleaned = code.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? code
        let data = try await get(path: "/rest/v1/friend_invites?code=eq.\(cleaned)&select=inviter,expires_at")
        guard let row = (try? JSONDecoder().decode([Row].self, from: data))?.first else { return nil }
        if let exp = DateHelpers.parseAPIDate(row.expires_at), exp < .now { return nil }
        guard row.inviter != uid else { return nil }
        // 409 (already friends) is success for our purposes — ignore it.
        _ = try? await post(path: "/rest/v1/friendships", body: [
            "requester_id": uid, "addressee_id": row.inviter, "status": "accepted",
        ])
        return try await getProfile(userId: row.inviter)
    }

    // MARK: - Friends

    func searchUsers(query: String) async throws -> [ArcUser] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let data = try await get(path: "/rest/v1/profiles?or=(handle.ilike.*\(encoded)*,display_name.ilike.*\(encoded)*)&select=*&limit=20")
        return try JSONDecoder().decode([ArcUser].self, from: data)
    }

    func sendFriendRequest(to userId: String) async throws {
        guard let uid = currentUser?.id else { return }
        let body: [String: Any] = [
            "requester_id": uid,
            "addressee_id": userId
        ]
        _ = try await post(path: "/rest/v1/friendships", body: body)
    }

    func acceptFriendRequest(friendshipId: String) async throws {
        _ = try await patch(path: "/rest/v1/friendships?id=eq.\(friendshipId)", body: ["status": "accepted"])
    }

    func removeFriend(friendshipId: String) async throws {
        _ = try await delete(path: "/rest/v1/friendships?id=eq.\(friendshipId)")
    }

    struct Friendship: Codable, Identifiable {
        let id: String
        let requester_id: String
        let addressee_id: String
        let status: String
    }

    func getFriends() async throws -> [Friendship] {
        guard let uid = currentUser?.id else { return [] }
        let data = try await get(path: "/rest/v1/friendships?or=(requester_id.eq.\(uid),addressee_id.eq.\(uid))&status=eq.accepted&select=*")
        return try JSONDecoder().decode([Friendship].self, from: data)
    }

    func getPendingRequests() async throws -> [Friendship] {
        guard let uid = currentUser?.id else { return [] }
        let data = try await get(path: "/rest/v1/friendships?addressee_id=eq.\(uid)&status=eq.pending&select=*")
        return try JSONDecoder().decode([Friendship].self, from: data)
    }

    func getProfile(userId: String) async throws -> ArcUser? {
        let data = try await get(path: "/rest/v1/profiles?id=eq.\(userId)&select=*")
        return try JSONDecoder().decode([ArcUser].self, from: data).first
    }

    // MARK: - Shared Flights

    struct SharedFlight: Codable, Identifiable {
        let id: String
        let user_id: String
        let flight_number: String
        let airline: String
        let departure_iata: String
        let arrival_iata: String
        let departure_city: String
        let arrival_city: String
        let departure_lat: Double?
        let departure_lon: Double?
        let arrival_lat: Double?
        let arrival_lon: Double?
        let scheduled_departure: String
        let scheduled_arrival: String
        let estimated_arrival: String?
        let status: String
        let delay_minutes: Int
        let departure_gate: String?
        let arrival_gate: String?
        let baggage_claim: String?
        let live_lat: Double?
        let live_lon: Double?
        let progress: Double
        let updated_at: String?
    }

    /// Upserts this flight's CURRENT state into `shared_flights` — the row
    /// friends (RLS-gated) and live share links (via the Worker) read.
    /// Conflict target is the natural key (user, flight number, scheduled
    /// departure), so every tracking poll can fire this idempotently instead
    /// of anyone having to remember row ids. Returns the row id, which a
    /// share link mints against.
    @discardableResult
    func shareFlight(_ flight: Flight) async throws -> String? {
        guard let uid = currentUser?.id else { return nil }
        // An empty audience still writes the row, it just admits nobody:
        // `auth.uid() = any('{}')` is false for every friend, so RLS hides it.
        //
        // Deleting instead would be wrong on two counts. It breaks the public
        // share link, which is a different thing from the friends feed — "no
        // friend sees this" and "I can't send my mum a live link" shouldn't be
        // the same switch. And it buys no data minimisation, because the flight
        // is mirrored to `user_flights` regardless.
        let iso = ISO8601DateFormatter()
        func str(_ d: Date?) -> Any { d.map { iso.string(from: $0) } ?? NSNull() }
        let body: [String: Any] = [
            "user_id": uid,
            "flight_number": flight.flightNumber,
            "airline": flight.airline,
            "departure_iata": flight.departureIATA,
            "arrival_iata": flight.arrivalIATA,
            "departure_city": flight.departureCity,
            "arrival_city": flight.arrivalCity,
            "departure_lat": flight.departureLat,
            "departure_lon": flight.departureLon,
            "arrival_lat": flight.arrivalLat,
            "arrival_lon": flight.arrivalLon,
            "scheduled_departure": iso.string(from: flight.scheduledDeparture),
            "scheduled_arrival": iso.string(from: flight.scheduledArrival),
            "estimated_arrival": str(flight.estimatedArrival),
            "actual_departure": str(flight.actualDeparture),
            "actual_arrival": str(flight.actualArrival),
            "status": flight.statusRaw,
            "delay_minutes": flight.delayMinutes,
            "departure_gate": flight.departureGate as Any,
            "departure_terminal": flight.departureTerminal as Any,
            "arrival_gate": flight.arrivalGate as Any,
            "arrival_terminal": flight.arrivalTerminal as Any,
            "baggage_claim": flight.baggageClaim as Any,
            "aircraft_type": flight.aircraftType as Any,
            "live_lat": flight.liveLat as Any,
            "live_lon": flight.liveLon as Any,
            "live_altitude": flight.liveAltitude as Any,
            "live_speed": flight.liveSpeed as Any,
            "progress": flight.progress,
            "updated_at": iso.string(from: .now),
            // nil audience = everyone; the column is nullable for exactly this.
            "audience": flight.sharedWithIds as Any,
        ]
        let data = try await upsert(
            path: "/rest/v1/shared_flights?on_conflict=user_id,flight_number,scheduled_departure",
            body: body, returnRepresentation: true)
        return (try? JSONDecoder().decode([SharedFlightID].self, from: data))?.first?.id
    }

    /// Removes the shared copy when the user deletes a flight locally.
    func unshareFlight(flightNumber: String, scheduledDeparture: Date) async throws {
        guard let uid = currentUser?.id else { return }
        let iso = ISO8601DateFormatter().string(from: scheduledDeparture)
        let number = flightNumber.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? flightNumber
        _ = try await delete(path: "/rest/v1/shared_flights?user_id=eq.\(uid)&flight_number=eq.\(number)&scheduled_departure=eq.\(iso)")
    }

    func getFriendFlights(userId: String) async throws -> [SharedFlight] {
        let data = try await get(path: "/rest/v1/shared_flights?user_id=eq.\(userId)&select=*&order=scheduled_departure.desc&limit=20")
        return try JSONDecoder().decode([SharedFlight].self, from: data)
    }

    /// One query for ALL friends' flights — the list and the map both consume
    /// this, so opening the Friends tab costs a single round-trip, not N.
    func friendsFlights(userIds: [String]) async throws -> [SharedFlight] {
        guard !userIds.isEmpty else { return [] }
        let list = userIds.joined(separator: ",")
        let data = try await get(path: "/rest/v1/shared_flights?user_id=in.(\(list))&select=*&order=scheduled_departure.desc&limit=60")
        return try JSONDecoder().decode([SharedFlight].self, from: data)
    }

    // MARK: - Flight Sync (private cloud backup)
    //
    // Separate from `shared_flights` above, which is scoped to the Friends/
    // social feature and only carries a trimmed subset of fields meant for
    // sharing. This mirrors the full local SwiftData record so a flight isn't
    // *only* stored on-device. Local-first, always: every call here is a
    // best-effort background mirror fired after the local save/delete already
    // succeeded — sync failing (or the user not being signed in at all) never
    // blocks or breaks the on-device experience, which must keep working fully
    // offline regardless of Supabase's configuration or auth state.

    /// Upserts one flight into `user_flights`, keyed by its local UUID so
    /// add/update both resolve to the same row.
    func upsertUserFlight(_ flight: Flight) async throws {
        guard let uid = currentUser?.id else { return }
        let body = Self.userFlightBody(flight, userId: uid)
        _ = try await upsert(path: "/rest/v1/user_flights", body: body)
    }

    func deleteUserFlight(id: UUID) async throws {
        guard currentUser != nil else { return }
        _ = try await delete(path: "/rest/v1/user_flights?id=eq.\(id.uuidString)")
    }

    /// Backfills every given flight — called once right after a successful
    /// sign-in, so flights added before the user ever signed in also end up
    /// backed up, not just ones added afterward.
    func bulkUploadFlights(_ flights: [Flight]) async {
        for flight in flights {
            try? await upsertUserFlight(flight)
        }
    }

    /// Uploads the recorded ADS-B breadcrumb track after landing. Conflict key
    /// is the table's (user_id, flight_number, flight_date) unique constraint —
    /// not the row's own generated id — so re-landing the same flight (status
    /// flapping, re-poll) overwrites rather than erroring or duplicating.
    func uploadFlightTrack(_ flight: Flight) async throws {
        guard let uid = currentUser?.id else { return }
        let points = flight.trackPoints
        guard !points.isEmpty else { return }
        let iso = ISO8601DateFormatter()
        let day = flight.scheduledDeparture.formatted(.iso8601.year().month().day())
        let body: [String: Any] = [
            "user_id": uid,
            "flight_number": flight.flightNumber,
            "departure_iata": flight.departureIATA,
            "arrival_iata": flight.arrivalIATA,
            "flight_date": day,
            "track_points": points.map { p in
                var d: [String: Any] = ["lat": p.lat, "lon": p.lon, "timestamp": iso.string(from: p.timestamp)]
                if let alt = p.altitude { d["altitude"] = alt }
                return d
            },
        ]
        _ = try await upsert(path: "/rest/v1/flight_tracks?on_conflict=user_id,flight_number,flight_date", body: body)
    }

    /// Builds the upsert body for a flight. Pure/static so it's testable
    /// without a network call or a signed-in session.
    static func userFlightBody(_ flight: Flight, userId: String) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        func str(_ d: Date?) -> Any { d.map { iso.string(from: $0) } ?? NSNull() }
        return [
            "id": flight.id.uuidString,
            "user_id": userId,
            "flight_number": flight.flightNumber,
            "airline": flight.airline,
            "airline_icao": flight.airlineICAO,
            "departure_iata": flight.departureIATA,
            "arrival_iata": flight.arrivalIATA,
            "departure_city": flight.departureCity,
            "arrival_city": flight.arrivalCity,
            "departure_lat": flight.departureLat,
            "departure_lon": flight.departureLon,
            "arrival_lat": flight.arrivalLat,
            "arrival_lon": flight.arrivalLon,
            "scheduled_departure": iso.string(from: flight.scheduledDeparture),
            "scheduled_arrival": iso.string(from: flight.scheduledArrival),
            "actual_departure": str(flight.actualDeparture),
            "actual_arrival": str(flight.actualArrival),
            "estimated_arrival": str(flight.estimatedArrival),
            "status": flight.statusRaw,
            "delay_minutes": flight.delayMinutes,
            "departure_gate": flight.departureGate as Any,
            "departure_terminal": flight.departureTerminal as Any,
            "arrival_gate": flight.arrivalGate as Any,
            "arrival_terminal": flight.arrivalTerminal as Any,
            "baggage_claim": flight.baggageClaim as Any,
            "aircraft_type": flight.aircraftType as Any,
            "aircraft_registration": flight.aircraftRegistration as Any,
            "aircraft_icao24": flight.aircraftICAO24 as Any,
            "booking_code": flight.bookingCode as Any,
            "seat": flight.seat as Any,
            "notes": flight.notes,
            "updated_at": iso.string(from: .now),
        ]
    }

    // MARK: - Shared Journeys

    /// Returns an active share code for this shared-flight row, minting one
    /// if none exists — and bumps the 48-hour expiry either way, so re-sharing
    /// the same flight keeps one stable link alive instead of scattering codes.
    func journeyCode(forFlightId flightId: String) async throws -> String {
        guard let uid = currentUser?.id else { throw ArcError.notSignedIn }
        let iso = ISO8601DateFormatter()
        let newExpiry = iso.string(from: Date.now.addingTimeInterval(48 * 3600))
        let data = try await get(path: "/rest/v1/shared_journeys?flight_id=eq.\(flightId)&user_id=eq.\(uid)&is_active=eq.true&select=share_code")
        if let code = (try? JSONDecoder().decode([SharedJourneyCode].self, from: data))?.first?.share_code {
            _ = try? await patch(path: "/rest/v1/shared_journeys?share_code=eq.\(code)", body: ["expires_at": newExpiry])
            return code
        }
        let code = generateShareCode()
        let body: [String: Any] = [
            "flight_id": flightId,
            "user_id": uid,
            "share_code": code,
            "expires_at": newExpiry,
        ]
        _ = try await post(path: "/rest/v1/shared_journeys", body: body)
        return code
    }

    private struct SharedJourneyCode: Codable { let share_code: String }

    func deactivateJourney(code: String) async throws {
        _ = try await patch(path: "/rest/v1/shared_journeys?share_code=eq.\(code)", body: ["is_active": false])
    }

    struct SharedJourney: Codable {
        let id: String
        let share_code: String
        let is_active: Bool
        let flight_id: String
    }

    func getMyJourneys() async throws -> [SharedJourney] {
        guard let uid = currentUser?.id else { return [] }
        let data = try await get(path: "/rest/v1/shared_journeys?user_id=eq.\(uid)&is_active=eq.true&select=*")
        return try JSONDecoder().decode([SharedJourney].self, from: data)
    }

    // MARK: - Watchers

    func watchFlight(flightId: String) async throws {
        guard let uid = currentUser?.id else { return }
        let body: [String: Any] = [
            "watcher_id": uid,
            "flight_id": flightId
        ]
        _ = try await post(path: "/rest/v1/watchers", body: body)
    }

    func unwatchFlight(flightId: String) async throws {
        guard let uid = currentUser?.id else { return }
        _ = try await delete(path: "/rest/v1/watchers?watcher_id=eq.\(uid)&flight_id=eq.\(flightId)")
    }

    // MARK: - HTTP Helpers

    // Every call funnels through `send` — the one place that touches the
    // network, and therefore the one place that has to check the status code.
    // Ignoring it meant an expired token looked exactly like success: writes
    // silently no-opped (invite links pointing at rows that were never
    // created) and reads handed PostgREST's error object to a decoder, which
    // surfaced as "the data couldn't be read" instead of "you're signed out".

    private func request(_ method: String, _ path: String,
                         body: [String: Any]? = nil, prefer: String? = nil) throws -> URLRequest {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = method
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    /// Authorises, validates, and — on a 401 — refreshes once and retries.
    /// An hour-old token is the normal state of an app opened days apart, not
    /// an error worth showing anyone. If the refresh itself fails the session
    /// is genuinely dead, so drop it and let the app ask for a name again
    /// rather than failing forever with no way back.
    private func send(_ original: URLRequest, authorised: Bool = true,
                      retrying: Bool = false) async throws -> Data {
        var request = original
        if authorised {
            request.setValue("Bearer \(accessToken ?? anonKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 401, authorised, !retrying {
            if await refreshSession() {
                return try await send(original, authorised: true, retrying: true)
            }
            signOut()
        }
        guard (200..<300).contains(status) else {
            throw ArcError.server(Self.errorMessage(data) ?? "Request failed (\(status)).")
        }
        return data
    }

    /// PostgREST and GoTrue both report failures as a JSON object; lift the
    /// human-readable part out so callers show "JWT expired", not a decode error.
    static func errorMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["message", "error_description", "msg", "error"] {
            if let message = object[key] as? String, !message.isEmpty { return message }
        }
        return nil
    }

    private func get(path: String) async throws -> Data {
        try await send(request("GET", path))
    }

    private func post(path: String, body: [String: Any], auth: Bool = true, returnData: Bool = false) async throws -> Data {
        try await send(request("POST", path, body: body,
                               prefer: returnData ? "return=representation" : nil),
                       authorised: auth)
    }

    /// INSERT ... ON CONFLICT (primary key) DO UPDATE, via PostgREST's
    /// merge-duplicates resolution — lets add and update both call the same
    /// method without needing to know in advance whether the row exists yet.
    private func upsert(path: String, body: [String: Any], returnRepresentation: Bool = false) async throws -> Data {
        try await send(request("POST", path, body: body,
                               prefer: returnRepresentation
                                   ? "resolution=merge-duplicates,return=representation"
                                   : "resolution=merge-duplicates"))
    }

    private func patch(path: String, body: [String: Any]) async throws -> Data {
        try await send(request("PATCH", path, body: body))
    }

    private func delete(path: String) async throws -> Data {
        try await send(request("DELETE", path))
    }

    // MARK: - Utilities

    private func generateShareCode() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<8).map { _ in chars.randomElement()! })
    }

    private func decodeJWTUserId(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String else { return nil }
        return sub
    }

    private struct AuthResponse: Codable {
        let access_token: String
        let refresh_token: String
    }

    private struct SharedFlightID: Codable {
        let id: String
    }

    enum ArcError: LocalizedError {
        case notSignedIn
        case notConfigured
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn: "You're not signed in."
            case .notConfigured: "Social features aren't configured."
            case .server(let message): message
            }
        }
    }
}

/// Where the session lives.
///
/// The anonymous refresh token IS the identity in this app — there's no email
/// to recover an account with. UserDefaults is erased by delete-and-reinstall,
/// so storing it there quietly minted a brand-new person on every reinstall and
/// orphaned their friendships. The Keychain survives reinstalls; this doesn't.
enum TokenStore {
    static func read(forKey key: String) -> String? {
        if let value = keychainValue(forKey: key) { return value }
        // One-time migration off UserDefaults so an existing session carries
        // over the upgrade instead of starting yet another identity.
        guard let legacy = UserDefaults.standard.string(forKey: key) else { return nil }
        write(legacy, forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        return legacy
    }

    static func write(_ value: String?, forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ch.arc.session",
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        guard let data = value?.data(using: .utf8) else { return }   // nil clears
        var insert = query
        insert[kSecValueData as String] = data
        // Background refreshes run while the phone is locked; this is the
        // loosest accessibility that still never leaves the device.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(insert as CFDictionary, nil)
    }

    private static func keychainValue(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ch.arc.session",
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
