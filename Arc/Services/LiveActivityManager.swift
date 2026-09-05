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
        // One clock, the same function the Worker uses. Lock, compact Island
        // and expanded Island all bind these fields — a second formula here
        // is how they drifted apart on VY8462.
        let clock = FlightActivityAttributes.ContentState.clock(
            scheduledDeparture: flight.scheduledDeparture,
            scheduledArrival: flight.scheduledArrival,
            delayMinutes: flight.delayMinutes,
            actualDeparture: flight.actualDeparture,
            estimatedArrival: flight.estimatedArrival,
            actualArrival: flight.actualArrival)
        // Boarding windows are airport concepts. A rail leg's "BER" is
        // Berlin Hbf, not Berlin Brandenburg — asking the airport tables
        // about it returns another vehicle's answer.
        let boardingLead = Self.boardingLeadMinutes(for: flight)
        let boardingTime = boardingLead.map { clock.departureTime.addingTimeInterval(TimeInterval(-$0 * 60)) }

        return FlightActivityAttributes.ContentState(
            status: flight.statusRaw,
            departureTime: clock.departureTime,
            arrivalTime: clock.arrivalTime,
            boardingTime: boardingTime,
            delayMinutes: clock.delayMinutes,
            // Arrival delay is its own number: the provider revises arrival
            // independently (estimatedArrival), so a 20m late departure can
            // still arrive on time — or vice versa.
            arrivalDelayMinutes: clock.arrivalDelayMinutes,
            // Local knock-on wins when it's live; otherwise keep a Worker
            // insight so a 60s local update doesn't wipe the smart line.
            insight: flight.liveActivityInsight ?? existing,
            companions: friendName == nil ? await companionsState(for: flight) : nil,
            // Authoritative even when empty: the seat lives in the STATE now,
            // because the attributes' copy is frozen at card start.
            seat: flight.seat ?? "",
            updatedAt: .now,
            departureGate: flight.departureGate,
            departureTerminal: flight.departureTerminal,
            arrivalGate: flight.arrivalGate,
            arrivalTerminal: flight.arrivalTerminal,
            baggageClaim: flight.baggageClaim,
            progress: flight.progress,
            // The gate-to-runway evidence, so the lock screen can hold the
            // hedge for this airport's real taxi with nothing running.
            offBlock: flight.offBlock,
            estimatedTakeoff: flight.estimatedTakeoff,
            actualDeparture: flight.actualDeparture,
            groundState: flight.groundStateRaw,
            groundObservedAt: flight.groundObservedAt,
            taxiStartedAt: flight.taxiStartedAt,
            lastSeenOnGround: flight.lastSeenOnGround,
            taxiPriorMinutes: flight.taxiPriorMinutes
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

    /// Same plane: number + route, ignoring spaces on the number. Own and
    /// friend cards for VY8462 BCN→LIS are one flight — the Island and the
    /// lock screen each pick a card, so two activities is two clocks.
    nonisolated static func isSamePlane(_ a: FlightActivityAttributes,
                                        _ b: FlightActivityAttributes) -> Bool {
        isSamePlane(a, number: b.flightNumber, departureIATA: b.departureIATA, arrivalIATA: b.arrivalIATA)
    }

    nonisolated static func isSamePlane(_ a: FlightActivityAttributes,
                                        number: String, departureIATA: String, arrivalIATA: String) -> Bool {
        a.flightNumber.replacingOccurrences(of: " ", with: "").uppercased()
            == number.replacingOccurrences(of: " ", with: "").uppercased()
            && a.departureIATA.uppercased() == departureIATA.uppercased()
            && a.arrivalIATA.uppercased() == arrivalIATA.uppercased()
    }

    /// Starting (or keeping) the traveller's own card ends the friend's.
    /// Companions already live on the own card; a second activity for the
    /// same plane is what let lock and Island disagree.
    nonisolated static func preferOwnOverFriend(existing: FlightActivityAttributes,
                                                incomingIsOwn: Bool) -> Bool {
        incomingIsOwn && existing.friendName != nil
    }

    func startActivity(for flight: Flight, friendName: String? = nil, friendAvatarFile: String? = nil,
                       friendFlightId: String? = nil) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let key = Self.activityKey(for: flight, friendName: friendName)

        // One card per plane. If this is the traveller's own activity, any
        // friend card for the same route goes — companions already appear
        // on this header, and a leftover friend card is a second ContentState.
        if friendName == nil {
            await endFriendActivity(flightNumber: flight.flightNumber,
                                    departureIATA: flight.departureIATA)
        } else if Activity<FlightActivityAttributes>.activities.contains(where: {
            $0.attributes.friendName == nil &&
            Self.isSamePlane($0.attributes,
                             number: flight.flightNumber,
                             departureIATA: flight.departureIATA,
                             arrivalIATA: flight.arrivalIATA)
        }) {
            // Traveller is on this plane — companions live on the own card.
            return
        }

        // Don't start a duplicate of the SAME kind. Own vs friend used to
        // both be kept; that is exactly two clocks on one plane.
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
            // The friend's shared_flights row id, so a tap on their card
            // opens THEIR flight — the transient Flight's own id is minted
            // per refresh and exists in nobody's store.
            friendFlightId: friendName == nil ? nil : friendFlightId,
            flightId: friendName == nil ? flight.id.uuidString : nil,
            modeRaw: flight.mode.rawValue,
            dataTierRaw: flight.dataTier.rawValue,
            departureTZID: flight.departureTZID,
            arrivalTZID: flight.arrivalTZID
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
    /// re-evaluates the phase from the clock. Pointing staleDate at the NEXT
    /// boundary makes the layout switch pre → taxi → in-flight → after at
    /// exactly the right moment even with the app dead and the device
    /// offline — which is precisely the in-flight situation. While online,
    /// pushes keep resetting it anyway.
    private static func staleDate(for state: FlightActivityAttributes.ContentState) -> Date {
        if state.status == "landed" { return .now.addingTimeInterval(3600) }
        // The "directions to the airport" pill retires ~1¾ h before
        // departure — schedule the re-render that removes it.
        let directionsCutoff = state.departureTime.addingTimeInterval(-105 * 60)
        if Date.now < directionsCutoff { return directionsCutoff }
        if Date.now < state.departureTime { return state.departureTime }
        // The hedge ends at the EXPECTED WHEELS-UP, not at the gate time
        // plus a constant: at a hub that taxis 35 minutes, a 20-minute grace
        // expires while the aircraft is still in the queue for the runway,
        // and the lock screen of someone sitting in that queue announced she
        // was flying. Schedule the re-render for the moment the label may
        // legitimately change (the offline-takeoff case).
        let wheelsUp = state.expectedWheelsUp
        if state.actualDeparture == nil, Date.now < wheelsUp { return wheelsUp }
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
        // One ActivityContent, one update. ActivityKit replaces the whole
        // state on every presentation — there is no "lock only" or "Island
        // only" write. A half-updated card is worse than a stale matching one.
        let content = ActivityContent(state: state, staleDate: Self.staleDate(for: state))
        nonisolated(unsafe) let act = activity
        await act.update(content)
        // Boarding lead and companions are ours alone to know, and a server
        // push restates the whole card from the Worker's own view — so the
        // Worker has to be told. Cheap: this only makes a request when the
        // blob actually changed, which is a handful of times per flight.
        if friendName == nil { await LiveActivityPushSync.syncExtras(for: flight) }
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

    /// Ends every extra activity that shows the same flight (same number +
    /// departure + own/friend kind). Duplicates could accumulate through the
    /// old adoption bug or a relaunch race; the lock screen must never stack
    /// two cards for one plane. Called once per app start.
    func reapDuplicateActivities() async {
        var keep: [String: Activity<FlightActivityAttributes>] = [:]
        let tracked = Set(activeActivities.values.map(\.id))
        for activity in Activity<FlightActivityAttributes>.activities {
            let a = activity.attributes
            // One identity per plane — not per own/friend kind. A leftover
            // friend card next to the traveller's own is two ContentStates
            // for one flight, which is the VY8462 lock-vs-Island split.
            let identity = "\(a.flightNumber.replacingOccurrences(of: " ", with: "").uppercased())|\(a.departureIATA.uppercased())|\(a.arrivalIATA.uppercased())"
            if let kept = keep[identity] {
                let dropKept = (a.friendName == nil && kept.attributes.friendName != nil)
                    || (tracked.contains(activity.id) && !tracked.contains(kept.id))
                let loser = dropKept ? kept : activity
                let winner = dropKept ? activity : kept
                nonisolated(unsafe) let act = loser
                await act.end(nil, dismissalPolicy: .immediate)
                keep[identity] = winner
            } else {
                keep[identity] = activity
            }
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

        let clock = FlightActivityAttributes.ContentState.clock(
            scheduledDeparture: flight.scheduledDeparture,
            scheduledArrival: flight.scheduledArrival,
            delayMinutes: flight.delayMinutes,
            actualDeparture: flight.actualDeparture,
            estimatedArrival: flight.estimatedArrival,
            actualArrival: flight.actualArrival)
        let finalState = FlightActivityAttributes.ContentState(
            status: "landed",
            departureTime: clock.departureTime,
            arrivalTime: clock.arrivalTime,
            boardingTime: nil,
            delayMinutes: clock.delayMinutes,
            arrivalDelayMinutes: clock.arrivalDelayMinutes,
            departureGate: flight.departureGate,
            departureTerminal: flight.departureTerminal,
            arrivalGate: flight.arrivalGate,
            arrivalTerminal: flight.arrivalTerminal,
            baggageClaim: flight.baggageClaim,
            progress: 1.0
        )

        let content = ActivityContent(state: finalState, staleDate: nil)
        nonisolated(unsafe) let act = activity
        await act.end(content, dismissalPolicy: .after(.now + 3600))
        activeActivities.removeValue(forKey: flightId)
    }

    // MARK: - Smart Boarding Time Estimates

    /// How many minutes before off-block boarding starts, or nil for a mode
    /// with no boarding concept. Travels to the Worker as this LEAD rather
    /// than as an instant: the Worker re-derives boarding from whatever the
    /// delay-adjusted departure currently is, so a delay moves boarding with
    /// it and a server push stops blanking the line altogether.
    static func boardingLeadMinutes(for flight: Flight) -> Int? {
        guard flight.mode.hasAirportOperations else { return nil }
        return estimateBoardingMinutes(airline: flight.airlineICAO, duration: flight.duration)
    }

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
