import Foundation
import ActivityKit
import SwiftData

/// Bridges ActivityKit's push channel to the rest of Arc — in both directions.
///
/// **Out:** push tokens go to the Worker so Live Activities can be updated
/// (and started) server-side via APNs, which is what makes the lock screen
/// genuinely live with the app closed.
///
/// **In:** the pushes that come back are treated as DATA, not just as pixels.
/// This is the half that matters in the air. Airline "free messaging" Wi-Fi
/// whitelists Apple's push endpoints so iMessage works, and Live Activity
/// updates ride that same connection — so a push reaches the phone at 38,000
/// feet even though nothing else does. Note where the network actually is:
/// only the Apple→device leg crosses the plane's Wi-Fi. The Worker→Apple leg
/// happened on the ground. The aircraft never has to reach our backend, which
/// is exactly why the payload has to be self-sufficient and why we read it
/// back into SwiftData instead of firing off a fetch we cannot complete.
///
/// One observation point covers everything: `activityUpdates` yields every
/// newly started activity regardless of whether WE requested it locally or
/// the server started it via push-to-start.
@MainActor
enum LiveActivityPushSync {
    private static var started = false
    private static var container: ModelContainer?
    /// The extras blob last registered per token, so a re-registration costs
    /// a request only when the device actually learned something new.
    private static var registeredExtras: [String: String] = [:]

    /// The push-to-start token this device last registered. Persisted, because
    /// the rotation that supersedes it usually happens in a LATER launch —
    /// held in memory it would be nil exactly when it is needed.
    private static let lastStartTokenKey = "arc.la.lastStartToken"
    private static var lastStartToken: String? {
        get { UserDefaults.standard.string(forKey: lastStartTokenKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastStartTokenKey) }
    }

    /// The APNs environment this INSTALL's tokens belong to, read off the
    /// signing profile rather than the build configuration — see
    /// `APNsEnvironment`. The Worker routes each token to the matching host,
    /// so getting this wrong is not a degradation, it is silence.
    private static var apnsEnv: String { APNsEnvironment.current }

    static func start(modelContainer: ModelContainer) {
        container = modelContainer
        guard !started else { return }
        started = true

        // Push-to-start token: lets the server START a Live Activity for an
        // upcoming flight even if the app hasn't been opened in days.
        // The owner id is REQUIRED server-side: the cron only starts
        // activities for the token owner's own flights, and sends nothing
        // for ownerless tokens — so wait briefly for sign-in if it races us.
        Task {
            for await tokenData in Activity<FlightActivityAttributes>.pushToStartTokenUpdates {
                let token = hex(tokenData)
                var body: [String: Any] = [
                    "token": token,
                    "type": "start",
                    "env": apnsEnv,
                    "user_id": await ownerId() as Any,
                ]
                // iOS mints a NEW push-to-start token whenever it rotates one,
                // and the previous token is dead from that moment. Nothing
                // said so, so every rotation left a row behind: 187 had piled
                // up for a single tester, and each one is a push the cron will
                // spend a subrequest on the next time a flight comes into
                // range. Only the device can name its own predecessor — the
                // server sees tokens, not devices, and cannot tell a rotation
                // from a second phone — so the device names it.
                if let previous = lastStartToken, previous != token {
                    body["replaces"] = previous
                }
                guard let json = try? JSONSerialization.data(withJSONObject: body) else { continue }
                await FlightAPIClient.shared.registerLiveActivityToken(json)
                // Only after the registration lands: a token recorded before
                // the request succeeded would name a row that still exists as
                // the one to drop next time, and the real predecessor would
                // survive for ever.
                lastStartToken = token
            }
        }

        // Per-activity update tokens, for both locally- and remotely-started
        // activities. Tokens can rotate mid-flight, hence the inner loop.
        Task {
            for await activity in Activity<FlightActivityAttributes>.activityUpdates {
                observe(activity)
            }
        }

        // Activities that already existed before this launch (started in a
        // previous session) don't come through activityUpdates — pick them up
        // explicitly or their tokens would never re-register after a relaunch.
        for activity in Activity<FlightActivityAttributes>.activities {
            observe(activity)
        }
    }

    /// Read every live activity's CURRENT state back into the store.
    ///
    /// `contentUpdates` only delivers while the app is running, and the whole
    /// point of a push is that it arrives when the app is not. ActivityKit
    /// still holds the latest state it was pushed, so the app catches up by
    /// asking on every foreground — which, in the air, is the only way fresh
    /// facts reach the model at all.
    static func reconcile() {
        for activity in Activity<FlightActivityAttributes>.activities {
            absorb(activity.content.state, from: activity.attributes)
        }
    }

    /// The signed-in Supabase user id, waiting up to ~10 s for the session to
    /// load when token registration races app start. nil if truly signed out.
    private static func ownerId() async -> String? {
        for _ in 0..<20 {
            if let id = ArcSupabase.shared.currentUser?.id { return id }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return ArcSupabase.shared.currentUser?.id
    }

    private static func observe(_ activity: Activity<FlightActivityAttributes>) {
        Task {
            for await tokenData in activity.pushTokenUpdates {
                var body = registrationBody(for: activity, token: hex(tokenData))
                body["user_id"] = await ownerId() as Any
                guard let json = try? JSONSerialization.data(withJSONObject: body) else { continue }
                await FlightAPIClient.shared.registerLiveActivityToken(json)
                registeredExtras[hex(tokenData)] = extrasFingerprint(activity)
            }
        }
        Task {
            for await content in activity.contentUpdates {
                absorb(content.state, from: activity.attributes)
            }
        }
        Task {
            for await state in activity.activityStateUpdates {
                if state == .ended || state == .dismissed {
                    if let token = activity.pushToken {
                        registeredExtras.removeValue(forKey: hex(token))
                        await FlightAPIClient.shared.unregisterLiveActivityToken(hex(token))
                    }
                }
            }
        }
        // Anything pushed while the app was away is already sitting in
        // `content.state`; the stream above will never replay it.
        absorb(activity.content.state, from: activity.attributes)
    }

    // MARK: - Pushes in

    /// Fold a pushed content state back into the stored flight.
    ///
    /// The merge is deliberately asymmetric. Provider facts (gates, belts,
    /// delay) are the Worker's to state. Departure EVIDENCE is not: the device
    /// reads the aircraft about a minute before the provider does, so a push
    /// may add a confirmation but must never take one away, and never wind a
    /// sighting backwards to an older one.
    private static func absorb(_ state: FlightActivityAttributes.ContentState,
                               from attributes: FlightActivityAttributes) {
        // A friend's activity describes THEIR flight; it is not ours to write.
        guard attributes.friendName == nil, let container else { return }

        // The MAIN context, not a fresh one: this is what every `@Query` in the
        // app is bound to, so absorbing a push updates the screen the traveller
        // is looking at rather than waiting for a cross-context merge.
        let context = container.mainContext
        let found: Flight?
        if let idString = attributes.flightId, let id = UUID(uuidString: idString) {
            var descriptor = FetchDescriptor<Flight>(predicate: #Predicate<Flight> { $0.id == id })
            descriptor.fetchLimit = 1
            found = try? context.fetch(descriptor).first
        } else {
            // A card the SERVER started: push-to-start attributes carried no
            // flightId until the Worker learned to send one, and attributes
            // are minted for life — so without this fallback every push to
            // such a card painted the lock screen and reached neither the
            // store nor the widget, and the tracker re-announced it all the
            // next time the app opened. Identity is the number and route;
            // the closest scheduled departure tells the daily sibling apart,
            // the same rule as the Worker's own leg matching.
            found = matchFlight((try? context.fetch(FetchDescriptor<Flight>())) ?? [],
                                number: attributes.flightNumber,
                                dep: attributes.departureIATA, arr: attributes.arrivalIATA,
                                around: state.departureTime)
        }
        guard let flight = found else { return }

        // Every write is guarded by an inequality. `reconcile()` runs on every
        // foreground and most pushes restate a card that has not moved, so an
        // unguarded absorb would dirty the store and spend a WidgetKit reload
        // on nothing several times a minute.
        var changed = false

        // Provider facts. A null must not erase what the device already knew —
        // the same rule the widget's own refresh follows.
        if !WidgetFlight.statusRegresses(state.status, from: flight.statusRaw),
           flight.statusRaw != state.status {
            flight.statusRaw = state.status
            changed = true
        }
        if flight.delayMinutes != state.delayMinutes {
            flight.delayMinutes = state.delayMinutes
            changed = true
        }
        if let v = state.departureGate, flight.departureGate != v {
            flight.departureGate = v; changed = true
        }
        if let v = state.departureTerminal, flight.departureTerminal != v {
            flight.departureTerminal = v; changed = true
        }
        if let v = state.arrivalGate, flight.arrivalGate != v {
            flight.arrivalGate = v; changed = true
        }
        if let v = state.arrivalTerminal, flight.arrivalTerminal != v {
            flight.arrivalTerminal = v; changed = true
        }
        if let v = state.baggageClaim, flight.baggageClaim != v {
            flight.baggageClaim = v; changed = true
        }
        if let v = state.taxiPriorMinutes, flight.taxiPriorMinutes != v {
            flight.taxiPriorMinutes = v; changed = true
        }
        if let v = state.estimatedTakeoff, flight.estimatedTakeoff != v {
            flight.estimatedTakeoff = v; changed = true
        }
        // `insight` is deliberately not absorbed: Flight.liveActivityInsight is
        // computed from local knock-on data, and the Worker's phrasing already
        // travels on the card itself.

        // Departure evidence: add, never subtract.
        if flight.actualDeparture == nil, let confirmed = state.actualDeparture {
            flight.actualDeparture = confirmed
            changed = true
        }
        if let observed = state.groundObservedAt,
           observed > (flight.groundObservedAt ?? .distantPast) {
            flight.groundObservedAt = observed
            flight.groundStateRaw = state.groundState
            changed = true
        }
        if let taxi = state.taxiStartedAt, flight.taxiStartedAt == nil {
            flight.taxiStartedAt = taxi
            changed = true
        }
        if let seen = state.lastSeenOnGround,
           seen > (flight.lastSeenOnGround ?? .distantPast) {
            flight.lastSeenOnGround = seen
            changed = true
        }

        // The arrival the card is counting down to. Only when the push carries
        // a revision — `arrivalTime` falls back to schedule+delay, and writing
        // that over a provider estimate would be a downgrade dressed as news.
        if state.arrivalDelayMinutes != nil, state.arrivalTime != flight.scheduledArrival,
           flight.estimatedArrival != state.arrivalTime {
            flight.estimatedArrival = state.arrivalTime
            changed = true
        }

        guard changed else { return }
        // This IS a successful refresh — it just arrived over the push channel
        // rather than over HTTP. Saying so is what stops the detail view
        // reading "Offline • Cached 40m ago" on a card that updated seconds ago.
        flight.lastStatusUpdate = state.updatedAt ?? .now
        try? context.save()

        // Widgets can neither receive a push nor make this call themselves.
        // The App Group snapshot is the only way the home screen sees any of
        // this, so an absorbed push re-publishes it.
        if let all = try? context.fetch(FetchDescriptor<Flight>()) {
            WidgetSync.sync(flights: all)
        }
    }

    // MARK: - Registration

    /// Facts only this device can know, so the Worker can restate them.
    ///
    /// A Live Activity push REPLACES the whole content state — ActivityKit
    /// does not merge — so anything the Worker cannot restate disappears from
    /// the lock screen on the next tick. Boarding travels as a LEAD in minutes
    /// rather than an instant so it keeps tracking the delay-adjusted
    /// departure instead of freezing at the original schedule.
    private static func localExtras(for activity: Activity<FlightActivityAttributes>) -> [String: Any] {
        var out: [String: Any] = [:]
        let state = activity.content.state
        if let boarding = state.boardingTime {
            out["boarding_lead_minutes"] = Int(
                (state.offBlock ?? state.departureTime).timeIntervalSince(boarding) / 60)
        }
        // The current seat: the attributes' copy is frozen at card start, so
        // a seat edited in the app reaches the lock screen only through the
        // state — and the Worker must echo it or its next push erases it.
        if let seat = state.seat {
            out["seat"] = seat
        }
        let iso = ISO8601DateFormatter()
        // Wheels-up the device witnessed. Evidence only — not the displayed
        // departure clock. A push that omits this loses TakeoffSensor.
        if let actual = state.actualDeparture {
            out["actual_departure"] = iso.string(from: actual)
        }
        // Hero arrival (until-gate / Arc ✦). ActivityKit REPLACES the whole
        // state: if the Worker's cached leg has no arr_estimated, it must
        // restate this or the next push writes schedule+delay over 21:00.
        out["estimated_arrival"] = iso.string(from: state.heroArrival)
        if let companions = state.companions, !companions.isEmpty,
           let encoded = try? JSONEncoder().encode(companions),
           let array = (try? JSONSerialization.jsonObject(with: encoded)) as? [Any] {
            out["companions"] = array
        }
        return out
    }

    private static func extrasFingerprint(_ activity: Activity<FlightActivityAttributes>) -> String {
        let extras = localExtras(for: activity)
        guard let data = try? JSONSerialization.data(withJSONObject: extras, options: .sortedKeys)
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Re-register when — and only when — the device's own extras changed.
    /// Companions come and go rarely; re-posting them on every 60-second
    /// local update would be a request a minute for a blob that never moves.
    static func syncExtras(for flight: Flight) async {
        guard let activity = Activity<FlightActivityAttributes>.activities.first(where: {
            $0.attributes.flightId == flight.id.uuidString && $0.attributes.friendName == nil
        }), let token = activity.pushToken else { return }
        let key = hex(token)
        let fingerprint = extrasFingerprint(activity)
        guard registeredExtras[key] != fingerprint else { return }
        registeredExtras[key] = fingerprint
        var body = registrationBody(for: activity, token: key)
        body["user_id"] = await ownerId() as Any
        guard let json = try? JSONSerialization.data(withJSONObject: body) else { return }
        await FlightAPIClient.shared.registerLiveActivityToken(json)
    }

    /// Everything the Worker's cron needs to keep pushing without a database
    /// lookup: identity from the attributes, schedule from the content state.
    private static func registrationBody(for activity: Activity<FlightActivityAttributes>, token: String) -> [String: Any] {
        let attrs = activity.attributes
        let state = activity.content.state
        let iso = ISO8601DateFormatter()
        return [
            "token": token,
            "type": "update",
            "env": apnsEnv,
            "local": localExtras(for: activity),
            "flight": [
                "flight_number": attrs.flightNumber,
                "departure_iata": attrs.departureIATA,
                "arrival_iata": attrs.arrivalIATA,
                "departure_city": attrs.departureCity,
                "arrival_city": attrs.arrivalCity,
                "airline": attrs.airline,
                "aircraft_type": attrs.aircraftType as Any,
                "seat": (state.seat ?? attrs.seat) as Any,
                // state.departureTime/arrivalTime are EFFECTIVE times —
                // makeState already added the known delay. The Worker adds
                // the provider's current delay on top of what we send here,
                // so sending them as-is double-counts every delay known at
                // registration. Reconstruct the true schedule.
                "scheduled_departure": iso.string(from: state.departureTime
                    .addingTimeInterval(-Double(max(0, state.delayMinutes)) * 60)),
                "scheduled_arrival": iso.string(from: state.arrivalTime
                    .addingTimeInterval(-Double(state.arrivalDelayMinutes ?? max(0, state.delayMinutes)) * 60)),
            ],
        ]
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// The stored flight a card with no flightId describes, or nil when no
    /// candidate is close enough to be it. `around` is the card's (effective)
    /// departure; anything beyond half a day is another day's operation, not
    /// a delayed one — the same drift rule the Worker's leg matching uses.
    nonisolated static func matchFlight(_ flights: [Flight], number: String,
                                        dep: String, arr: String, around: Date) -> Flight? {
        let wanted = number.replacingOccurrences(of: " ", with: "").uppercased()
        let candidates = flights.filter {
            $0.flightNumber.replacingOccurrences(of: " ", with: "").uppercased() == wanted
                && $0.departureIATA.uppercased() == dep.uppercased()
                && $0.arrivalIATA.uppercased() == arr.uppercased()
        }
        func drift(_ f: Flight) -> TimeInterval { abs(f.scheduledDeparture.timeIntervalSince(around)) }
        guard let best = candidates.min(by: { drift($0) < drift($1) }),
              drift(best) <= 12 * 3600 else { return nil }
        return best
    }
}
