import Foundation
import ActivityKit

/// Manages Live Activities for active flights.
/// Shows flight progress on lock screen and Dynamic Island.
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var activeActivities: [String: Activity<FlightActivityAttributes>] = [:]

    /// Friends on this same flight (avatar staged, seat along), for the
    /// header of the traveller's OWN activity. Never on a friend activity —
    /// there the flight is the friend's, and they'd list themselves.
    private func companionsState(for flight: Flight) async -> [FlightActivityAttributes.Companion]? {
        let matches = FriendsStore.shared.companions(for: flight)
        guard !matches.isEmpty else { return nil }
        var out: [FlightActivityAttributes.Companion] = []
        for match in matches.prefix(6) {
            let file = await LiveActivityAvatarStore.ensureAvatar(
                userId: match.user.id, urlString: match.user.avatar_url)
            out.append(.init(name: match.user.display_name, seat: match.seat, avatarFile: file))
        }
        return out
    }

    private func makeState(for flight: Flight, preservingInsight existing: String? = nil,
                           friendName: String? = nil) async -> FlightActivityAttributes.ContentState {
        // Use actual departure if available, otherwise adjust scheduled by delay
        let depTime: Date
        if let actual = flight.actualDeparture {
            depTime = actual
        } else if flight.delayMinutes > 0 {
            depTime = flight.scheduledDeparture.addingTimeInterval(Double(flight.delayMinutes) * 60)
        } else {
            depTime = flight.scheduledDeparture
        }
        // Boarding windows and security queues are airport concepts. A rail
        // leg's "BER" is Berlin Hbf, not Berlin Brandenburg — asking the
        // airport tables about it returns another vehicle's answer.
        var boardingTime: Date? = nil
        var securityWait: Int? = nil
        if flight.mode.hasAirportOperations {
            let boardingMinutes = Self.estimateBoardingMinutes(airline: flight.airlineICAO, duration: flight.duration)
            boardingTime = depTime.addingTimeInterval(-Double(boardingMinutes) * 60)

            // Fetch security wait time while the user could still be landside.
            // ("delayed" was checked here before, but that string never occurs —
            // the Worker normalizes it to "scheduled". boarding/gateClosed are
            // real statuses where the wait is no longer actionable, so skip them.)
            if flight.statusRaw == "scheduled" {
                securityWait = try? await FlightAPIClient.shared.securityWaitTime(iata: flight.departureIATA)?.securityMinutes
            }
        }

        // Delay shifts the arrival too, matching depTime above — the
        // lock screen otherwise counts down to an arrival that passed.
        let arrTime = flight.estimatedArrival
            ?? flight.scheduledArrival.addingTimeInterval(Double(max(0, flight.delayMinutes)) * 60)

        return FlightActivityAttributes.ContentState(
            status: flight.statusRaw,
            departureTime: depTime,
            arrivalTime: arrTime,
            boardingTime: boardingTime,
            securityWaitMinutes: securityWait,
            delayMinutes: flight.delayMinutes,
            // Arrival delay is its own number: the provider revises arrival
            // independently (estimatedArrival), so a 20m late departure can
            // still arrive on time — or vice versa.
            arrivalDelayMinutes: Int((arrTime.timeIntervalSince(flight.scheduledArrival) / 60).rounded()),
            // Local knock-on wins when it's live; otherwise keep a Worker
            // insight so a 60s local update doesn't wipe the smart line.
            insight: flight.liveActivityInsight ?? existing,
            companions: friendName == nil ? await companionsState(for: flight) : nil,
            departureGate: flight.departureGate,
            departureTerminal: flight.departureTerminal,
            arrivalGate: flight.arrivalGate,
            arrivalTerminal: flight.arrivalTerminal,
            baggageClaim: flight.baggageClaim,
            altitude: flight.liveAltitude.map { $0 * 3.281 },
            speed: flight.liveSpeed.map { $0 * 1.944 },
            heading: flight.liveHeading,
            progress: flight.progress
        )
    }

    /// Where a friend's activity lives in `activeActivities`. Transient friend
    /// flights mint a NEW UUID on every refresh, so keying them by flight id
    /// added a fresh dictionary entry (holding an Activity) each cycle —
    /// unbounded growth. Keyed by identity instead.
    private static func activityKey(for flight: Flight, friendName: String?) -> String {
        friendName == nil
            ? flight.id.uuidString
            : "friend-\(flight.flightNumber)-\(flight.departureIATA)"
    }

    func startActivity(for flight: Flight, friendName: String? = nil, friendAvatarFile: String? = nil) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let key = Self.activityKey(for: flight, friendName: friendName)

        // Don't start a duplicate. OWN and FRIEND activities for the same
        // flight are different things — you and Anna can be on LX318 at once,
        // and adopting hers as yours put her name on your lock screen (and
        // your landing ended her card).
        if let existing = Activity<FlightActivityAttributes>.activities.first(where: {
            $0.attributes.flightNumber == flight.flightNumber &&
            $0.attributes.departureIATA == flight.departureIATA &&
            $0.attributes.arrivalIATA == flight.arrivalIATA &&
            ($0.attributes.friendName == nil) == (friendName == nil)
        }) {
            activeActivities[key] = existing
            return
        }
        guard activeActivities[key] == nil else { return }

        let attributes = FlightActivityAttributes(
            flightNumber: flight.flightNumber,
            departureIATA: flight.departureIATA,
            arrivalIATA: flight.arrivalIATA,
            departureCity: flight.departureCity,
            arrivalCity: flight.arrivalCity,
            airline: flight.airline,
            aircraftType: flight.aircraftType,
            seat: flight.seat,
            friendName: friendName,
            friendAvatarFile: friendAvatarFile,
            flightId: friendName == nil ? flight.id.uuidString : nil,
            modeRaw: flight.mode.rawValue,
            dataTierRaw: flight.dataTier.rawValue
        )

        let state = await makeState(for: flight, friendName: friendName)
        do {
            // pushType .token: ActivityKit hands us an APNs token for this
            // activity, LiveActivityPushSync registers it with the Worker, and
            // the Worker's cron pushes updates server-side — the activity keeps
            // moving with the app fully closed. Local update()/end() below
            // still work exactly the same alongside push.
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: Self.staleDate(for: state)),
                pushType: .token
            )
            activeActivities[key] = activity
        } catch {
            print("[Arc] Failed to start Live Activity: \(error)")
        }
    }

    /// staleDate doubles as our offline phase-flip scheduler: iOS re-renders
    /// the Live Activity view once when content goes stale, and that render
    /// re-evaluates `effectivePhase(Date.now)`. Pointing staleDate at the
    /// NEXT phase boundary (departure while pre-flight, arrival while
    /// in-flight) makes the layout switch pre → during → after at exactly
    /// the right moment even with the app dead and the device offline —
    /// which is precisely the in-flight situation. While online, pushes
    /// keep resetting it anyway.
    private static func staleDate(for state: FlightActivityAttributes.ContentState) -> Date {
        if state.status == "landed" { return .now.addingTimeInterval(3600) }
        // The "directions to the airport" pill retires ~1¾ h before
        // departure — schedule the re-render that removes it.
        let directionsCutoff = state.departureTime.addingTimeInterval(-105 * 60)
        if Date.now < directionsCutoff { return directionsCutoff }
        if Date.now < state.departureTime { return state.departureTime }
        // The widget hedges "Departing…" for 20 min past an UNCONFIRMED
        // departure — schedule the re-render that ends the hedge and flips
        // to the in-flight layout (the offline-takeoff case).
        let departingGraceEnd = state.departureTime.addingTimeInterval(20 * 60)
        if state.status != "active", Date.now < departingGraceEnd { return departingGraceEnd }
        return max(state.arrivalTime, .now.addingTimeInterval(60))
    }

    func updateActivity(for flight: Flight, friendName: String? = nil) async {
        // `activeActivities` is in-memory only. After an app relaunch
        // mid-flight, the tracker never calls startActivity for an
        // already-active flight (that path only runs pre-departure), so
        // without this reconciliation every update would silently no-op and
        // the Live Activity would stay frozen at its pre-relaunch state.
        // Own and friend activities reconcile separately — matching on route
        // alone let your update adopt (and then end) a friend's card.
        let key = Self.activityKey(for: flight, friendName: friendName)
        if activeActivities[key] == nil {
            if let existing = Activity<FlightActivityAttributes>.activities.first(where: {
                $0.attributes.flightNumber == flight.flightNumber &&
                $0.attributes.departureIATA == flight.departureIATA &&
                $0.attributes.arrivalIATA == flight.arrivalIATA &&
                ($0.attributes.friendName == nil) == (friendName == nil)
            }) {
                activeActivities[key] = existing
            }
        }
        guard let activity = activeActivities[key] else { return }

        let state = await makeState(for: flight, preservingInsight: activity.content.state.insight,
                                    friendName: friendName)
        let content = ActivityContent(state: state, staleDate: Self.staleDate(for: state))
        nonisolated(unsafe) let act = activity
        await act.update(content)
    }

    /// Ends any FRIEND activity for this flight. Friend LAs have no stable
    /// local id (they're built from transient models), so matching is by
    /// flight identity — restricted to friendName-tagged activities so a
    /// family member on YOUR OWN flight can never end your own activity.
    func endFriendActivity(flightNumber: String, departureIATA: String) async {
        for activity in Activity<FlightActivityAttributes>.activities
        where activity.attributes.flightNumber == flightNumber &&
              activity.attributes.departureIATA == departureIATA &&
              activity.attributes.friendName != nil {
            nonisolated(unsafe) let act = activity
            await act.end(nil, dismissalPolicy: .default)
        }
    }

    func endActivity(for flight: Flight) async {
        // Same relaunch reconciliation as `updateActivity`: the in-memory map
        // is empty after a cold start, and a delete/cancel that couldn't find
        // its activity left a live countdown running for a trip that no
        // longer existed, with a dead tap target.
        if activeActivities[flight.id.uuidString] == nil {
            if let existing = Activity<FlightActivityAttributes>.activities.first(where: {
                $0.attributes.flightNumber == flight.flightNumber &&
                $0.attributes.departureIATA == flight.departureIATA &&
                $0.attributes.arrivalIATA == flight.arrivalIATA &&
                $0.attributes.friendName == nil
            }) {
                activeActivities[flight.id.uuidString] = existing
            }
        }
        guard let activity = activeActivities[flight.id.uuidString] else { return }
        let flightId = flight.id.uuidString

        // Only a LANDED flight earns the landed card. A cancelled flight or a
        // deleted trip must not linger for an hour wearing a green tick and a
        // baggage belt — it just goes.
        guard flight.status == .landed else {
            nonisolated(unsafe) let act = activity
            await act.end(nil, dismissalPolicy: .immediate)
            activeActivities.removeValue(forKey: flightId)
            return
        }

        let finalArrival = flight.actualArrival ?? flight.effectiveArrival
        let finalState = FlightActivityAttributes.ContentState(
            status: "landed",
            departureTime: flight.actualDeparture ?? flight.scheduledDeparture,
            arrivalTime: finalArrival,
            boardingTime: nil,
            securityWaitMinutes: nil,
            delayMinutes: flight.delayMinutes,
            arrivalDelayMinutes: Int((finalArrival.timeIntervalSince(flight.scheduledArrival) / 60).rounded()),
            departureGate: flight.departureGate,
            departureTerminal: flight.departureTerminal,
            arrivalGate: flight.arrivalGate,
            arrivalTerminal: flight.arrivalTerminal,
            baggageClaim: flight.baggageClaim,
            altitude: nil,
            speed: nil,
            heading: nil,
            progress: 1.0
        )

        let content = ActivityContent(state: finalState, staleDate: nil)
        nonisolated(unsafe) let act = activity
        await act.end(content, dismissalPolicy: .after(.now + 3600))
        activeActivities.removeValue(forKey: flightId)
    }

    // MARK: - Smart Boarding Time Estimates

    /// Estimates how many minutes before departure boarding starts,
    /// based on airline and flight duration.
    private static func estimateBoardingMinutes(airline: String, duration: TimeInterval) -> Int {
        let icao = airline.uppercased()
        let isLongHaul = duration > 5 * 3600  // >5 hours

        // Airline-specific boarding times (minutes before departure)
        let airlineDefaults: [String: (shortHaul: Int, longHaul: Int)] = [
            // Low-cost carriers — board early, strict cutoffs
            "RYR": (45, 45),   // Ryanair
            "EZY": (40, 45),   // easyJet
            "EZS": (40, 45),   // easyJet Switzerland
            "WZZ": (40, 45),   // Wizz Air
            "VLG": (40, 45),   // Vueling
            "NKS": (45, 45),   // Spirit
            "FFT": (45, 45),   // Frontier

            // European legacy carriers
            "SWR": (35, 50),   // Swiss
            "DLH": (35, 50),   // Lufthansa
            "AUA": (35, 45),   // Austrian
            "BEL": (35, 45),   // Brussels Airlines
            "AFR": (35, 50),   // Air France
            "KLM": (35, 50),   // KLM
            "BAW": (35, 55),   // British Airways
            "SAS": (35, 45),   // SAS
            "TAP": (35, 45),   // TAP Portugal
            "IBE": (35, 50),   // Iberia
            "AZA": (35, 45),   // ITA Airways
            "THY": (40, 50),   // Turkish Airlines
            "AEE": (35, 45),   // Aegean

            // Middle East / long-haul specialists
            "UAE": (40, 60),   // Emirates
            "ETD": (40, 55),   // Etihad
            "QTR": (40, 55),   // Qatar Airways
            "SAA": (40, 50),   // Saudia

            // US carriers
            "AAL": (30, 45),   // American
            "DAL": (30, 45),   // Delta
            "UAL": (30, 45),   // United
            "SWA": (35, 35),   // Southwest
            "JBU": (30, 40),   // JetBlue

            // Asian carriers
            "SIA": (35, 55),   // Singapore Airlines
            "CPA": (35, 50),   // Cathay Pacific
            "ANA": (35, 50),   // ANA
            "JAL": (35, 50),   // JAL
        ]

        if let times = airlineDefaults[icao] {
            return isLongHaul ? times.longHaul : times.shortHaul
        }

        // Fallback defaults
        return isLongHaul ? 50 : 35
    }
}
