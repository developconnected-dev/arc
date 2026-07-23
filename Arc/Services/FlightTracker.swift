import Foundation
import SwiftData

/// Manages live flight tracking: periodic status updates, inbound monitoring, and position polling.
@MainActor
final class FlightTracker: ObservableObject {
    static let shared = FlightTracker()

    @Published var isTracking = false
    private var trackingTask: Task<Void, Never>?

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

        trackingTask = Task {
            while !Task.isCancelled {
                let now = Date.now

                for flight in flights {
                    guard !flight.isCompleted || flight.isRecentlyLanded else { continue }

                    let hoursUntilDep = flight.scheduledDeparture.timeIntervalSince(now) / 3600

                    // Smart polling: determine if this flight needs an update now
                    let pollInterval: TimeInterval
                    if flight.isActive {
                        pollInterval = 60           // In-flight: every 60s
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

                    // Start Live Activity within 3 hours (idempotent)
                    if flight.isUpcoming && hoursUntilDep <= 3 {
                        await LiveActivityManager.shared.startActivity(for: flight)
                        // Pre-cache everything before takeoff
                        await preCacheIfNeeded(flight: flight, modelContext: modelContext)
                    }

                    await LiveActivityManager.shared.updateActivity(for: flight)

                    // Live position: only for active flights, uses free OpenSky (not counted)
                    if let icao24 = flight.aircraftICAO24, flight.isActive {
                        await updateLivePosition(flight, icao24: icao24)
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

                try? modelContext.save()

                // Base loop interval: 60s (individual flights skip if not due)
                try? await Task.sleep(for: .seconds(60))
            }
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

    // MARK: - Burst Update (WiFi reconnection)

    /// Immediately fetches fresh data for all active/upcoming flights.
    /// Called when network reconnects (e.g. in-flight WiFi comes on).
    func burstUpdate(flights: [Flight], modelContext: ModelContext) async {
        let relevant = flights.filter { $0.isActive || $0.isUpcoming }
        for flight in relevant {
            await updateFlightStatus(flight)
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
            if let gate = latest.dep_gate, !gate.isEmpty { flight.departureGate = gate }
            if let terminal = latest.dep_terminal, !terminal.isEmpty { flight.departureTerminal = terminal }
            if let gate = latest.arr_gate, !gate.isEmpty { flight.arrivalGate = gate }
            if let terminal = latest.arr_terminal, !terminal.isEmpty { flight.arrivalTerminal = terminal }
            if let baggage = latest.arr_baggage, !baggage.isEmpty { flight.baggageClaim = baggage }

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
