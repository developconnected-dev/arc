import Foundation
import SwiftData

/// Manages live flight tracking: periodic status updates, inbound monitoring, and position polling.
@MainActor
final class FlightTracker: ObservableObject {
    static let shared = FlightTracker()

    @Published var isTracking = false
    private var trackingTask: Task<Void, Never>?
    private var lastConnectionRisk: ConnectionPlanner.Risk?
    private var observedGateSignature: [UUID: String] = [:]

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

        // Track last poll time per flight to implement smart polling tiers
        var lastPolled: [UUID: Date] = [:]
        var lastInboundCheck: [UUID: Date] = [:]
        var lastStandCheck: [UUID: Date] = [:]
        var lastPositionPoll: [UUID: Date] = [:]

        trackingTask = Task {
            while !Task.isCancelled {
                let now = Date.now

                for flight in flights {
                    guard !flight.isCompleted || flight.isRecentlyLanded else { continue }

                    // Runs before the polling tiers on purpose: they skip
                    // anything over 24h out, which is exactly the window a
                    // hand-entered flight is waiting in.
                    if ScheduleBackfill.isDue(flight, at: now) {
                        await ScheduleBackfill.check(flight, at: now)
                    }

                    let hoursUntilDep = flight.scheduledDeparture.timeIntervalSince(now) / 3600

                    // Smart polling. Status/ETA barely move mid-cruise — the
                    // things that visibly change (position, progress) come
                    // from OpenSky and clock math, both free. Tight cadence
                    // only where data actually moves: departure window,
                    // final approach, and just-landed. (The old flat 60s
                    // in-flight tier was ~480 API calls per long-haul and
                    // helped kill July's monthly quota.)
                    let pollInterval: TimeInterval
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
                        continue                    // More than 24h out: skip entirely
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

                    // Live position: only for active flights. OpenSky is "free"
                    // but NOT unmetered — anonymous access gets ~400 requests/day,
                    // and it's shared per source IP (worse through the Worker's
                    // shared Cloudflare egress). At 60s a single long-haul burns
                    // the whole budget mid-flight and positions silently freeze
                    // at the 429s. 3-minute polling keeps an 8h flight at ~160
                    // requests and still moves the plane visibly.
                    if let icao24 = flight.aircraftICAO24, flight.isActive {
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
                    if flight.arrivalGate == nil,
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
                    if flight.isUpcoming && hoursUntilDep <= 6 {
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
                    let arrTime = flight.estimatedArrival ?? flight.scheduledArrival

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
                if let pair = ConnectionPlanner.detectConnection(from: flights) {
                    let plan = ConnectionPlanner.plan(inbound: pair.inbound, outbound: pair.outbound)
                    if let last = lastConnectionRisk, rank(plan.risk) > rank(last) {
                        ArcNotifications.notifyConnectionRisk(plan)
                    }
                    lastConnectionRisk = plan.risk
                } else {
                    lastConnectionRisk = nil
                }

                try? modelContext.save()

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

    private func preCacheIfNeeded(flight: Flight, modelContext: ModelContext) async {
        guard !preCached.contains(flight.id) else { return }
        guard flight.isUpcoming else { return }
        let hoursOut = flight.scheduledDeparture.timeIntervalSince(.now) / 3600
        guard hoursOut <= 3 && hoursOut > 0 else { return }

        preCached.insert(flight.id)

        // Fetch latest status (gate, terminal, delay, aircraft)
        await updateFlightStatus(flight)

        // Fetch inbound aircraft
        await InboundMonitor.checkInbound(for: flight)

        // Fetch security wait time
        if let security = try? await FlightAPIClient.shared.securityWaitTime(iata: flight.departureIATA) {
            // Security data is passed via Live Activity, not stored on flight model
            // But we trigger a Live Activity update which will fetch it
        }

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
        let signature = [flight.departureGate, flight.departureTerminal,
                         flight.arrivalGate, flight.arrivalTerminal]
            .map { $0 ?? "-" }.joined(separator: "|")
        if signature != "-|-|-|-", observedGateSignature[flight.id] != signature {
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
            await pollWithChangeHandling(flight)
            await LiveActivityManager.shared.updateActivity(for: flight)
        }
        try? modelContext.save()
    }

    // MARK: - Status Change Handler

    private func handleStatusChange(flight: Flight, from oldStatus: String) async {
        switch flight.statusRaw {
        case "active":
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

    private func updateFlightStatus(_ flight: Flight) async {
        let dateStr = flight.scheduledDeparture.formatted(.iso8601.year().month().day())
        do {
            let results = try await FlightAPIClient.shared.searchFlight(
                number: flight.flightNumber,
                date: dateStr
            )
            guard let latest = results.first else { return }

            // Update status
            flight.statusRaw = FlightStatus.heal(rawValue: latest.status, scheduledArrival: flight.scheduledArrival).rawValue
            flight.delayMinutes = latest.delay ?? 0

            // Update actual times when available
            if let depActual = latest.dep_actual, let parsed = DateHelpers.parseAPIDate(depActual) {
                flight.actualDeparture = parsed
            }
            if let arrActual = latest.arr_actual, let parsed = DateHelpers.parseAPIDate(arrActual) {
                flight.actualArrival = parsed
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
            if let reg = latest.aircraft_registration, !reg.isEmpty { flight.aircraftRegistration = reg }
            if let icao24 = latest.aircraft_icao24, !icao24.isEmpty { flight.aircraftICAO24 = icao24 }
            flight.lastStatusUpdate = .now

        } catch {
            // Silently skip — will retry next cycle
        }
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
