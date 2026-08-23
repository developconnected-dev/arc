import Foundation
import SwiftData

/// Manages live flight tracking: periodic status updates, inbound monitoring, and position polling.
@MainActor
final class FlightTracker: ObservableObject {
    static let shared = FlightTracker()

    @Published var isTracking = false
    private var trackingTask: Task<Void, Never>?
    /// Keyed by the OUTBOUND leg: a 3-leg itinerary changes which pair is
    /// "the connection" mid-trip, and one un-keyed value compared risk across
    /// two different connections.
    private var lastConnectionRisk: [UUID: ConnectionPlanner.Risk] = [:]
    private var observedGateSignature: [UUID: String] = [:]
    // Poll clocks live on the instance: `startTracking` fires on every list
    // change, and clocks local to the task closure meant each add/delete
    // re-polled every flight from a clean slate.
    private var lastPolled: [UUID: Date] = [:]
    private var lastInboundCheck: [UUID: Date] = [:]
    private var lastStandCheck: [UUID: Date] = [:]
    private var lastPositionPoll: [UUID: Date] = [:]

    /// Start tracking all active and upcoming flights.
    func startTracking(flights: [Flight], modelContext: ModelContext) {
        stopTracking()
        isTracking = true

        // Set up WiFi reconnection burst updates
        NetworkMonitor.shared.onReconnect = { [weak self] in
            Task { @MainActor in
                await self?.burstUpdate(flights: flights, modelContext: modelContext)
            }
        }
        NetworkMonitor.shared.start()

        // Drop clocks for flights no longer tracked (deleted or long landed).
        let ids = Set(flights.map(\.id))
        lastPolled = lastPolled.filter { ids.contains($0.key) }
        lastInboundCheck = lastInboundCheck.filter { ids.contains($0.key) }
        lastStandCheck = lastStandCheck.filter { ids.contains($0.key) }
        lastPositionPoll = lastPositionPoll.filter { ids.contains($0.key) }

        trackingTask = Task {
            while !Task.isCancelled {
                let now = Date.now

                for flight in flights {
                    // The task is only CANCELLED on restart, never awaited —
                    // and a swipe-delete can destroy a model while this cycle
                    // is suspended at an await. A cancelled loop must stop
                    // writing, and a deleted model must never be touched.
                    guard !Task.isCancelled else { return }
                    guard !flight.isDeleted, flight.modelContext != nil else { continue }
                    guard !flight.isCompleted || flight.isRecentlyLanded else { continue }

                    // Runs before the polling tiers on purpose: they skip
                    // anything over 24h out, which is exactly the window a
                    // hand-entered flight is waiting in.
                    if ScheduleBackfill.isDue(flight, at: now) {
                        await ScheduleBackfill.check(flight, at: now)
                    }

                    // A sailing added without its line (Overpass was slow, or
                    // it predates sea routing) asks once for the OSM ferry
                    // path so the map stops drawing it across islands. Also
                    // runs for legs weeks out — the tiers below skip those,
                    // and the map shows them regardless.
                    if flight.mode == .sea, flight.routePath.isEmpty,
                       flight.departureLat != 0, flight.arrivalLat != 0,
                       !seaRouteTried.contains(flight.id) {
                        seaRouteTried.insert(flight.id)
                        if let path = await FlightAPIClient.shared.ferryRoute(
                            from: (flight.departureLat, flight.departureLon),
                            to: (flight.arrivalLat, flight.arrivalLon)) {
                            flight.routePathData = try? JSONEncoder().encode(path)
                        }
                    }

                    let hoursUntilDep = flight.scheduledDeparture.timeIntervalSince(now) / 3600

                    // Predicted gate: what this number usually gets, shown
                    // BEFORE the airline publishes one — the flywheel's whole
                    // purpose. One ask per flight per session (history moves
                    // daily, not hourly), only while there is no real gate,
                    // and never overwriting one: display always prefers fact.
                    if flight.mode == .air, flight.isUpcoming,
                       flight.departureGate == nil, flight.predictedDepartureGate == nil,
                       hoursUntilDep > 0, hoursUntilDep <= 48,
                       !gatePredictionTried.contains(flight.id) {
                        gatePredictionTried.insert(flight.id)
                        if let p = await FlightAPIClient.shared.gatePrediction(
                            flight: flight.flightNumber,
                            airport: flight.departureIATA, direction: "dep"),
                           p.isConfident {
                            guard !flight.isDeleted, flight.modelContext != nil else { continue }
                            flight.predictedDepartureGate = p.gate
                            flight.predictedDepartureTerminal = p.terminal
                        }
                    }

                    // Smart polling. Status/ETA barely move mid-cruise — the
                    // things that visibly change (position, progress) come
                    // from OpenSky and clock math, both free. Tight cadence
                    // only where data actually moves: departure window,
                    // final approach, and just-landed. (The old flat 60s
                    // in-flight tier was ~480 API calls per long-haul and
                    // helped kill July's monthly quota.)
                    var pollInterval: TimeInterval
                    if flight.isActive {
                        let minutesToArrival = flight.scheduledArrival
                            .addingTimeInterval(Double(flight.delayMinutes) * 60)
                            .timeIntervalSince(now) / 60
                        pollInterval = minutesToArrival <= 45 ? 2 * 60 : 5 * 60
                    } else if flight.isRecentlyLanded {
                        pollInterval = 120          // Just landed: every 2 min (baggage/gate updates)
                    } else if hoursUntilDep <= 3 {
                        pollInterval = 5 * 60       // Within 3 hours: every 5 min
                    } else if hoursUntilDep <= 24 {
                        pollInterval = 30 * 60      // Within 24 hours: every 30 min
                    } else {
                        // Further out: once a day. Schedule changes land weeks
                        // ahead, and a trip reading "Updated 11d ago" isn't
                        // being tracked in any sense the user recognises. The
                        // Worker's far-future cache makes this ~free.
                        pollInterval = 24 * 3600
                    }

                    // A timetable has nothing to say minute by minute. Where the
                    // source never reports a revised time, the only thing that
                    // can change is a published notice — hours, not minutes — so
                    // the tight tiers above would just spend quota to be told the
                    // same thing.
                    if !flight.reportsPunctuality {
                        pollInterval = max(pollInterval, 30 * 60)
                    }

                    // Check if enough time has passed since last poll
                    if let last = lastPolled[flight.id], now.timeIntervalSince(last) < pollInterval {
                        continue
                    }
                    lastPolled[flight.id] = now

                    await pollWithChangeHandling(flight)

                    // Start Live Activity within 3 hours (idempotent)
                    if flight.isUpcoming && hoursUntilDep <= 3 {
                        await LiveActivityManager.shared.startActivity(for: flight)
                        // Pre-cache everything before takeoff
                        await preCacheIfNeeded(flight: flight, modelContext: modelContext)
                    }

                    await LiveActivityManager.shared.updateActivity(for: flight)

                    // Live position: only while airborne, and at 3-minute cadence.
                    // The feed behind /position is free and unauthenticated
                    // (airplanes.live, after OpenSky started refusing
                    // Cloudflare's egress IPs), which is a reason to be modest
                    // rather than a licence: at 60s a single long-haul is ~480
                    // requests, and 3 minutes keeps an 8h flight near 160 while
                    // still moving the plane visibly.
                    //
                    // Dispatch on the leg's own position source rather than on
                    // whichever id happens to be set: a ferry's MMSI is nine
                    // digits where an ICAO24 is six hex, so handing one to the
                    // aircraft lookup returns some other vehicle's position and
                    // reports no error. (Trains have no free live-position feed,
                    // and AIS has no endpoint yet, so both simply have none.)
                    if flight.isActive, case .openSky(let icao24)? = flight.livePositionSource {
                        let lastPos = lastPositionPoll[flight.id] ?? .distantPast
                        if now.timeIntervalSince(lastPos) >= 180 {
                            await updateLivePosition(flight, icao24: icao24)
                            lastPositionPoll[flight.id] = now
                        }
                    }

                    // Arrival stand: only worth asking once the aircraft is
                    // airborne (stands firm up near landing), only while we
                    // still lack one, and at most every 10 minutes — it costs a
                    // whole-airport FIDS call, though the backend caches that
                    // per airport-hour so flights landing together share one.
                    if flight.mode.hasAirportOperations,
                       flight.arrivalGate == nil,
                       flight.isActive || flight.isRecentlyLanded,
                       let icao = ReferenceData.shared.airport(flight.arrivalIATA)?.icao,
                       !icao.isEmpty {
                        let lastStand = lastStandCheck[flight.id] ?? .distantPast
                        if now.timeIntervalSince(lastStand) >= 10 * 60 {
                            lastStandCheck[flight.id] = now
                            if let stand = await FlightAPIClient.shared.arrivalStand(
                                icao: icao, flight: flight.flightNumber,
                                arrival: flight.effectiveArrival, timeZone: flight.arrTimeZone) {
                                if let gate = stand.gate, !gate.isEmpty { flight.arrivalGate = gate }
                                if let terminal = stand.terminal, !terminal.isEmpty,
                                   flight.arrivalTerminal == nil { flight.arrivalTerminal = terminal }
                                if let belt = stand.belt, !belt.isEmpty,
                                   flight.baggageClaim == nil { flight.baggageClaim = belt }
                            }
                        }
                    }

                    // Inbound check: max once per 15 min (saves API calls)
                    if flight.mode.hasAirportOperations, flight.isUpcoming, hoursUntilDep <= 6 {
                        let lastCheck = lastInboundCheck[flight.id] ?? .distantPast
                        if now.timeIntervalSince(lastCheck) >= 15 * 60 {
                            await InboundMonitor.checkInbound(for: flight)
                            lastInboundCheck[flight.id] = now
                        }
                    }
                }

                // Time-based status healing: if the API didn't update the status,
                // detect it from the clock so the flight list and widget show correctly
                for flight in flights {
                    let depTime = flight.actualDeparture ?? flight.scheduledDeparture.addingTimeInterval(Double(flight.delayMinutes) * 60)
                    // The delay shifts the arrival too. Without it, a delayed
                    // airborne flight was force-"landed" at its ORIGINAL
                    // arrival time, then the next poll saw "active" from the
                    // API and flipped back — landed notifications and Live
                    // Activity churn every cycle until touchdown.
                    let arrTime = flight.estimatedArrival
                        ?? flight.scheduledArrival.addingTimeInterval(Double(flight.delayMinutes) * 60)

                    if (flight.statusRaw == "scheduled" || flight.statusRaw == "boarding" || flight.statusRaw == "gateClosed") && Date.now >= depTime {
                        let oldStatus = flight.statusRaw
                        flight.statusRaw = "active"
                        await handleStatusChange(flight: flight, from: oldStatus)
                    }

                    if flight.statusRaw == "active" && Date.now >= arrTime {
                        let oldStatus = flight.statusRaw
                        flight.statusRaw = "landed"
                        await handleStatusChange(flight: flight, from: oldStatus)
                    }
                }

                // Connection Assistant: re-rate the connection with the fresh
                // delays and alert when the tier WORSENS (never on improvement
                // or repetition — the notification id also dedupes per tier).
                let live = flights.filter { !$0.isDeleted && $0.modelContext != nil }
                if let pair = ConnectionPlanner.detectConnection(from: live) {
                    let plan = ConnectionPlanner.plan(inbound: pair.inbound, outbound: pair.outbound)
                    if let last = self.lastConnectionRisk[pair.outbound.id], rank(plan.risk) > rank(last) {
                        ArcNotifications.notifyConnectionRisk(plan)
                    }
                    self.lastConnectionRisk[pair.outbound.id] = plan.risk
                }

                guard !Task.isCancelled else { return }
                try? modelContext.save()

                // Re-write the App Group after every cycle: gate changes and
                // delays otherwise reached the Live Activity but not the
                // home-screen widget until the app was next foregrounded.
                WidgetSync.sync(flights: flights)

                // Base loop interval: 60s (individual flights skip if not due)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func rank(_ r: ConnectionPlanner.Risk) -> Int {
        switch r {
        case .relaxed: 0
        case .normal: 1
        case .tight: 2
        case .risky: 3
        }
    }

    func stopTracking() {
        trackingTask?.cancel()
        trackingTask = nil
        isTracking = false
    }

    // MARK: - Pre-Cache (aggressive fetch before takeoff)

    /// Aggressively fetches all available data for a flight before departure.
    /// Called when a flight enters the 3-hour window. Ensures gate, terminal,
    /// delay, aircraft, inbound status, and arrival info are all cached locally
    /// so the Live Activity has everything it needs even without internet.
    private var preCached: Set<UUID> = []
    /// Sea legs whose OSM line has been asked for this session — one ask per
    /// leg; a null answer (no line mapped) must not become a poll every minute.
    private var seaRouteTried: Set<UUID> = []
    /// Flights whose usual-gate prediction has been asked for this session —
    /// same one-ask discipline: "no pattern yet" must not re-poll per minute.
    private var gatePredictionTried: Set<UUID> = []

    private func preCacheIfNeeded(flight: Flight, modelContext: ModelContext) async {
        guard !preCached.contains(flight.id) else { return }
        guard flight.isUpcoming else { return }
        let hoursOut = flight.scheduledDeparture.timeIntervalSince(.now) / 3600
        guard hoursOut <= 3 && hoursOut > 0 else { return }

        preCached.insert(flight.id)

        // Fetch latest status (gate, terminal, delay, aircraft)
        await updateFlightStatus(flight)

        // Fetch inbound aircraft — there is no rotation to chase off air.
        if flight.mode.hasAirportOperations {
            await InboundMonitor.checkInbound(for: flight)
        }

        // Security wait isn't stored on the model — the Live Activity update
        // below fetches it itself, so a fetch here was a duplicate API call.

        // Update Live Activity with all cached data
        await LiveActivityManager.shared.updateActivity(for: flight)

        // Sync to widget (will be refreshed on next app foreground)

        try? modelContext.save()
    }

    // MARK: - Shared poll

    /// One data refresh WITH full change handling — notifications, Live
    /// Activity start/end, track upload all hang off status transitions, so
    /// every code path that refreshes a flight must run this, not a bare
    /// updateFlightStatus. (The reconnect burst used to skip it: a landing
    /// discovered via reconnect updated the UI but silently dropped the
    /// landed notification, the activity end, and the track upload.)
    private func pollWithChangeHandling(_ flight: Flight) async {
        let oldStatus = flight.statusRaw
        let oldDelay = flight.delayMinutes
        let oldGate = flight.departureGate

        await updateFlightStatus(flight)
        // The network round-trip above is exactly where a deletion can land.
        guard !flight.isDeleted, flight.modelContext != nil else { return }

        if flight.statusRaw != oldStatus {
            await handleStatusChange(flight: flight, from: oldStatus)
        }
        if flight.delayMinutes != oldDelay && flight.delayMinutes > 0 {
            ArcNotifications.notifyDelay(flight: flight)
        }
        if let newGate = flight.departureGate, newGate != oldGate {
            ArcNotifications.notifyGateChange(flight: flight, newGate: newGate)
        }

        // Gate-prediction flywheel: record what gates this flight used today.
        // Posted only when the observed set changes (the Worker additionally
        // upserts one row per flight/day, so storage can't grow per-poll).
        // Air only: the flywheel predicts gates from airport history, and a
        // platform number filed against a station's display code — which can
        // collide with a real IATA code — would poison it for a real airport.
        let signature = [flight.departureGate, flight.departureTerminal,
                         flight.arrivalGate, flight.arrivalTerminal]
            .map { $0 ?? "-" }.joined(separator: "|")
        if flight.mode.hasAirportOperations,
           signature != "-|-|-|-", observedGateSignature[flight.id] != signature {
            observedGateSignature[flight.id] = signature
            let body: [String: Any] = [
                "flight_number": flight.flightNumber,
                "departure_iata": flight.departureIATA,
                "arrival_iata": flight.arrivalIATA,
                "flight_date": flight.scheduledDeparture.formatted(.iso8601.year().month().day()),
                "dep_gate": flight.departureGate as Any,
                "dep_terminal": flight.departureTerminal as Any,
                "arr_gate": flight.arrivalGate as Any,
                "arr_terminal": flight.arrivalTerminal as Any,
            ]
            if let json = try? JSONSerialization.data(withJSONObject: body) {
                Task { await FlightAPIClient.shared.observeGates(json) }
            }
        }

        // Mirror the fresh state to shared_flights — this is what friends'
        // devices and live share links actually read, so it must ride every
        // poll, not just explicit share taps. No-ops when signed out.
        Task { try? await ArcSupabase.shared.shareFlight(flight) }
    }

    // MARK: - Burst Update (connectivity returns)

    /// Immediately fetches fresh data the moment ANY connectivity returns —
    /// mobile data after landing or in-flight WiFi. This is what flips the
    /// Live Activity straight to confirmed-landed (belt, gate, actual times)
    /// when the flight beat its cached ETA, without waiting for any timer.
    func burstUpdate(flights: [Flight], modelContext: ModelContext) async {
        // isRecentlyLanded matters most here: reconnecting right after
        // touchdown is exactly when the arrival gate and baggage belt appear,
        // and excluding just-landed flights meant the flight that most needed
        // the refresh was the one skipped.
        let relevant = flights.filter { $0.isActive || $0.isUpcoming || $0.isRecentlyLanded }
        for flight in relevant {
            // A delete can land while this burst is suspended mid-network —
            // a destroyed model must not be polled or saved.
            guard !flight.isDeleted, flight.modelContext != nil else { continue }
            await pollWithChangeHandling(flight)
            await LiveActivityManager.shared.updateActivity(for: flight)
        }
        try? modelContext.save()
    }

    // MARK: - Status Change Handler

    private func handleStatusChange(flight: Flight, from oldStatus: String) async {
        switch flight.statusRaw {
        case "active":
            // Freeze what Arc was claiming the moment the flight left — the
            // landed detail view shows prediction next to reality.
            flight.predictedDelayAtDeparture = flight.predictedDelayMinutes
            await LiveActivityManager.shared.startActivity(for: flight)
        case "landed":
            ArcNotifications.notifyLanded(flight: flight)
            await LiveActivityManager.shared.endActivity(for: flight)
            // Back up the recorded flight path (fire-and-forget; no-ops when
            // signed out or when no breadcrumbs were collected).
            let landed = flight
            Task { try? await ArcSupabase.shared.uploadFlightTrack(landed) }
        case "cancelled":
            ArcNotifications.notifyCancelled(flight: flight)
            await LiveActivityManager.shared.endActivity(for: flight)
        default:
            break
        }
    }

    // MARK: - Status Update

    /// One refresh of whatever this leg is.
    ///
    /// Every mode used to end up in the airline schedule lookup below, which for
    /// a saved train meant asking AeroDataBox about "ICE 373" on every poll
    /// forever: no match, no refresh, and — since a leg is skipped only when it
    /// is more than 24h out — a wasted request every five minutes for the whole
    /// day before departure. Trains and sailings are re-found through the
    /// provider that actually knows them.
    private func updateFlightStatus(_ flight: Flight) async {
        switch flight.mode {
        case .air: await refreshAirLeg(flight)
        case .rail: await refreshRailLeg(flight)
        case .sea: await refreshSeaLeg(flight)
        }
    }

    private func refreshAirLeg(_ flight: Flight) async {
        // ADB's date is the LOCAL departure date at the airport — UTC
        // formatting fetched yesterday's leg for early-morning departures.
        let dateStr = DateHelpers.apiDate(flight.scheduledDeparture, at: flight.departureIATA)
        do {
            let results = try await FlightAPIClient.shared.searchFlight(
                number: flight.flightNumber,
                date: dateStr
            )
            // One number often flies several legs a day (A→B→C); blindly
            // taking the first stamped the WRONG leg's status, gates and
            // actual times onto the tracked flight every poll.
            guard let latest = ScheduleBackfill.bestLeg(results, matching: flight, allowRouteChange: false) else { return }

            // Update status
            flight.statusRaw = FlightStatus.heal(rawValue: latest.status, scheduledArrival: flight.scheduledArrival).rawValue
            flight.delayMinutes = latest.delay ?? 0

            // Update actual times when available. Since the runway-time fix,
            // *_actual is a wheels-up/down FACT; the published revision rides
            // arr_estimated and only ever feeds the estimate.
            if let depActual = latest.dep_actual, let parsed = DateHelpers.parseAPIDate(depActual) {
                flight.actualDeparture = parsed
            }
            if let arrActual = latest.arr_actual, let parsed = DateHelpers.parseAPIDate(arrActual) {
                flight.actualArrival = parsed
                flight.estimatedArrival = parsed
            } else if let arrEst = latest.arr_estimated, let parsed = DateHelpers.parseAPIDate(arrEst) {
                flight.estimatedArrival = parsed
            }

            // Update gates if changed
            if let gate = latest.dep_gate, !gate.isEmpty {
                if let old = flight.departureGate, old != gate { flight.previousDepartureGate = old }
                flight.departureGate = gate
            }
            if let terminal = latest.dep_terminal, !terminal.isEmpty { flight.departureTerminal = terminal }
            if let gate = latest.arr_gate, !gate.isEmpty { flight.arrivalGate = gate }
            if let terminal = latest.arr_terminal, !terminal.isEmpty { flight.arrivalTerminal = terminal }
            if let baggage = latest.arr_baggage, !baggage.isEmpty { flight.baggageClaim = baggage }
            if let reg = latest.aircraft_registration, !reg.isEmpty {
                if let old = flight.aircraftRegistration, !old.isEmpty,
                   old.caseInsensitiveCompare(reg) != .orderedSame {
                    // Aircraft swap: the rotation chain and knock-on
                    // prediction describe a tail that no longer flies this
                    // leg — the airline swapping planes is exactly how a
                    // scary prediction gets resolved. Clear everything
                    // derived from the old tail and re-check the new one
                    // immediately instead of waiting out the 15-min throttle.
                    flight.rotationLegs = []
                    flight.predictedDelayMinutes = 0
                    flight.predictionReason = nil
                    flight.inboundChecked = false
                    flight.inboundFlightNumber = nil
                    flight.aircraftRegistration = reg
                    if let icao24 = latest.aircraft_icao24, !icao24.isEmpty { flight.aircraftICAO24 = icao24 }
                    let swapped = flight
                    Task { @MainActor in await InboundMonitor.checkInbound(for: swapped) }
                } else {
                    flight.aircraftRegistration = reg
                }
            }
            if let icao24 = latest.aircraft_icao24, !icao24.isEmpty { flight.aircraftICAO24 = icao24 }
            flight.lastStatusUpdate = .now

        } catch {
            // Silently skip — will retry next cycle
        }
    }

    // MARK: - Rail

    /// A train is re-found by its trip id, and when a feed rebuild has renumbered
    /// that id, by what the ticket says. Both steps are needed: the fast path
    /// costs one request, and without the fallback a train added weeks ahead
    /// stops refreshing at exactly the point it starts to matter.
    private func refreshRailLeg(_ flight: Flight) async {
        // Both the trip lookup and the board are addressed by the boarding stop's
        // provider id. A train typed in by hand has none, so there is nothing to
        // ask — as opposed to the airline feed, which was asked and always said no.
        guard let stopId = flight.departureStopID, !stopId.isEmpty else { return }

        if let stored = flight.railTripID, await applyRailTrip(stored, to: flight, from: stopId) {
            return
        }

        let key = RailServiceKey.make(
            operatorName: flight.airline, service: flight.flightNumber,
            boardingStopID: stopId, scheduledDeparture: flight.scheduledDeparture)
        guard let fresh = await FlightAPIClient.shared.railReresolve(
            stopId: stopId, key: key, at: flight.scheduledDeparture),
              fresh != flight.railTripID else { return }
        flight.railTripID = fresh
        _ = await applyRailTrip(fresh, to: flight, from: stopId)
    }

    /// False when the trip id didn't resolve to this journey, which is the signal
    /// to go back to the departure board for a current one.
    private func applyRailTrip(_ tripId: String, to flight: Flight, from stopId: String) async -> Bool {
        do {
            let legs = try await FlightAPIClient.shared.railTrip(
                tripId: tripId, from: stopId, to: flight.arrivalStopID)
            guard let leg = legs.first else { return false }
            apply(leg, to: flight)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Sea

    /// Nobody publishes a per-sailing delay, so refreshing a ferry means
    /// re-reading the crossing's own row in the timetable: its times, the
    /// operator's notice, and what the source now claims to know. Deriving a
    /// delay figure here would be Arc inventing one.
    private func refreshSeaLeg(_ flight: Flight) async {
        // Ferryhopper resolves port NAMES, which is what these hold for a sailing.
        guard let from = flight.departureStopID, !from.isEmpty,
              let to = flight.arrivalStopID, !to.isEmpty else { return }
        let date = DateHelpers.apiDate(flight.scheduledDeparture, in: flight.depTimeZone)
        guard let sailings = try? await FlightAPIClient.shared.ferrySearch(
            from: from, to: to, date: date) else { return }

        // One crossing runs several times a day and often with several vessels,
        // so the sailing is identified by both — matching on the route alone
        // would stamp the morning boat's times onto an evening booking.
        let vessel = flight.vesselName ?? flight.flightNumber
        let match = sailings.first {
            $0.flight_number.caseInsensitiveCompare(vessel) == .orderedSame
                && abs((DateHelpers.parseAPIDate($0.dep_scheduled) ?? .distantPast)
                    .timeIntervalSince(flight.scheduledDeparture)) < 90 * 60
        }
        // No match is not a cancellation. Ferryhopper drops and re-lists
        // crossings for reasons of its own, and a booking the user holds is
        // better left as they saved it than declared off on that evidence.
        guard let match else { return }
        apply(match, to: flight)
    }

    // MARK: - Transit refresh

    /// The parts of a rail or sea leg that can legitimately change after it was
    /// added: whether it is running, its real times, where to stand, and the
    /// operator's own notice.
    ///
    /// What it deliberately leaves alone is identity — stop ids, zones, route
    /// path, vessel — and the SCHEDULE. A refresh has no business rewriting which
    /// journey this is, and `scheduledDeparture` in particular is load-bearing
    /// twice over: it is the minute a train is re-identified by (`RailServiceKey`)
    /// and the value the departure reminder's notification id is built from, so
    /// moving it here would break recovery and orphan the reminder. Retiming
    /// arrives as a delay, which is the honest shape of it anyway.
    private func apply(_ r: FlightAPIClient.FlightSearchResult, to flight: Flight) {
        if let actual = r.dep_actual, let parsed = DateHelpers.parseAPIDate(actual) {
            flight.actualDeparture = parsed
        }
        if let actual = r.arr_actual, let parsed = DateHelpers.parseAPIDate(actual) {
            flight.actualArrival = parsed
            flight.estimatedArrival = parsed
        }
        flight.statusRaw = FlightStatus.heal(
            rawValue: r.status, scheduledArrival: flight.scheduledArrival).rawValue
        flight.delayMinutes = r.delay ?? 0
        // A live train can lose its realtime feed, and then the leg genuinely
        // knows less than it did — the tier travels with the answer, not with
        // whatever it was when the trip was added.
        if let tier = r.data_tier, let parsed = DataTier(rawValue: tier) {
            // A weekly-inferred timetable leg (the provider has a hole for
            // this date right now) must not demote a flight that already had
            // a live record — that would flap "On Time" off and on.
            if !(flight.dataTier == .live && parsed == .scheduled && flight.mode == .air) {
                flight.dataTier = parsed
            }
        }
        // A re-platformed train reuses the gate-change machinery built for
        // flights, so the "platform changed" alert lights up for free.
        if let boardingPoint = r.dep_gate, !boardingPoint.isEmpty {
            if let old = flight.departureGate, old != boardingPoint {
                flight.previousDepartureGate = old
            }
            flight.departureGate = boardingPoint
        }
        if let arriving = r.arr_gate, !arriving.isEmpty { flight.arrivalGate = arriving }
        // Prose, shown verbatim: parsing "reduced service due to weather" into a
        // delay figure would manufacture a precision nobody stated.
        if let note = r.disruption_note, !note.isEmpty, note != flight.disruptionNote {
            flight.disruptionNote = note
            flight.disruptionSeenAt = .now
        }
        flight.lastStatusUpdate = .now
    }

    // MARK: - Live Position

    private func updateLivePosition(_ flight: Flight, icao24: String) async {
        do {
            guard let pos = try await FlightAPIClient.shared.livePosition(icao24: icao24) else { return }
            flight.liveLat = pos.lat
            flight.liveLon = pos.lon
            flight.liveAltitude = pos.altitude
            flight.liveSpeed = pos.velocity
            flight.liveHeading = pos.heading
            flight.liveUpdatedAt = .now

            // Store breadcrumb for actual flight path visualization
            flight.appendTrackPoint(lat: pos.lat, lon: pos.lon, altitude: pos.altitude)

            // Compute smarter arrival ETA from live position + speed
            if pos.velocity > 10, flight.arrivalLat != 0 {
                let smartArrival = flight.smartETA
                // Only update if meaningfully different from current estimate
                let currentEst = flight.estimatedArrival ?? flight.scheduledArrival
                if abs(smartArrival.timeIntervalSince(currentEst)) > 120 { // >2 min difference
                    flight.estimatedArrival = smartArrival
                }
            }
        } catch {
            // Silently skip
        }
    }
}
