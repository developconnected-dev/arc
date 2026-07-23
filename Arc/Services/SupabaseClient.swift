import Foundation
import AuthenticationServices

/// Lightweight Supabase client using REST API directly — no SDK dependency.
/// Handles auth (Sign in with Apple), profiles, flights, friendships, shared journeys, and watchers.
@MainActor
final class ArcSupabase: ObservableObject {
    static let shared = ArcSupabase()

    @Published var isSignedIn = false
    @Published var currentUser: ArcUser?

    private var accessToken: String? {
        didSet { UserDefaults.standard.set(accessToken, forKey: "arc_access_token") }
    }
    private var refreshToken: String? {
        didSet { UserDefaults.standard.set(refreshToken, forKey: "arc_refresh_token") }
    }

    private let baseURL: String
    private let anonKey: String

    struct ArcUser: Codable, Identifiable {
        let id: String
        var display_name: String
        var handle: String?
        var avatar_url: String?
        var home_airport: String?
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
        self.accessToken = UserDefaults.standard.string(forKey: "arc_access_token")
        self.refreshToken = UserDefaults.standard.string(forKey: "arc_refresh_token")
        self.isSignedIn = accessToken != nil
    }

    var isConfigured: Bool { !baseURL.isEmpty && !anonKey.isEmpty }

    // MARK: - Auth

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

    func updateProfile(displayName: String? = nil, handle: String? = nil, homeAirport: String? = nil) async throws {
        guard let uid = currentUser?.id else { return }
        var body: [String: Any] = [:]
        if let name = displayName { body["display_name"] = name }
        if let h = handle { body["handle"] = h }
        if let airport = homeAirport { body["home_airport"] = airport }

        _ = try await patch(path: "/rest/v1/profiles?id=eq.\(uid)", body: body)
        await loadProfile()
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
        let scheduled_departure: String
        let scheduled_arrival: String
        let status: String
        let delay_minutes: Int
        let departure_gate: String?
        let arrival_gate: String?
        let progress: Double
    }

    func syncFlight(_ flight: Flight) async throws -> String {
        guard let uid = currentUser?.id else { throw ArcError.notSignedIn }

        let body: [String: Any] = [
            "user_id": uid,
            "flight_number": flight.flightNumber,
            "airline": flight.airline,
            "departure_iata": flight.departureIATA,
            "arrival_iata": flight.arrivalIATA,
            "departure_city": flight.departureCity,
            "arrival_city": flight.arrivalCity,
            "scheduled_departure": ISO8601DateFormatter().string(from: flight.scheduledDeparture),
            "scheduled_arrival": ISO8601DateFormatter().string(from: flight.scheduledArrival),
            "status": flight.statusRaw,
            "delay_minutes": flight.delayMinutes,
            "departure_gate": flight.departureGate as Any,
            "arrival_gate": flight.arrivalGate as Any,
            "baggage_claim": flight.baggageClaim as Any,
            "aircraft_type": flight.aircraftType as Any,
            "live_lat": flight.liveLat as Any,
            "live_lon": flight.liveLon as Any,
            "live_altitude": flight.liveAltitude as Any,
            "live_speed": flight.liveSpeed as Any,
            "progress": flight.progress
        ]

        let data = try await post(path: "/rest/v1/shared_flights", body: body, returnData: true)
        let results = try JSONDecoder().decode([SharedFlightID].self, from: data)
        return results.first?.id ?? ""
    }

    func updateSharedFlight(id: String, flight: Flight) async throws {
        let body: [String: Any] = [
            "status": flight.statusRaw,
            "delay_minutes": flight.delayMinutes,
            "departure_gate": flight.departureGate as Any,
            "arrival_gate": flight.arrivalGate as Any,
            "baggage_claim": flight.baggageClaim as Any,
            "live_lat": flight.liveLat as Any,
            "live_lon": flight.liveLon as Any,
            "live_altitude": flight.liveAltitude as Any,
            "live_speed": flight.liveSpeed as Any,
            "progress": flight.progress,
            "updated_at": ISO8601DateFormatter().string(from: .now)
        ]
        _ = try await patch(path: "/rest/v1/shared_flights?id=eq.\(id)", body: body)
    }

    func getFriendFlights(userId: String) async throws -> [SharedFlight] {
        let data = try await get(path: "/rest/v1/shared_flights?user_id=eq.\(userId)&select=*&order=scheduled_departure.desc&limit=20")
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

    func createSharedJourney(flightId: String) async throws -> String {
        guard let uid = currentUser?.id else { throw ArcError.notSignedIn }
        let code = generateShareCode()
        let body: [String: Any] = [
            "flight_id": flightId,
            "user_id": uid,
            "share_code": code
        ]
        _ = try await post(path: "/rest/v1/shared_journeys", body: body)
        return code
    }

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

    private func get(path: String) async throws -> Data {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.setValue("Bearer \(accessToken ?? anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    private func post(path: String, body: [String: Any], auth: Bool = true, returnData: Bool = false) async throws -> Data {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if returnData {
            request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        }
        if auth {
            request.setValue("Bearer \(accessToken ?? anonKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    /// INSERT ... ON CONFLICT (primary key) DO UPDATE, via PostgREST's
    /// merge-duplicates resolution — lets add and update both call the same
    /// method without needing to know in advance whether the row exists yet.
    private func upsert(path: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.setValue("Bearer \(accessToken ?? anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    private func patch(path: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken ?? anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    private func delete(path: String) async throws -> Data {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken ?? anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
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
