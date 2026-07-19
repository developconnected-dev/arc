import Foundation
import SwiftData

/// Manages live flight tracking: periodic status updates, inbound monitoring, and position polling.
@MainActor
final class FlightTracker: ObservableObject {
    static let shared = FlightTracker()

    @Published var isTracking = false
    private var trackingTask: Task<Void, Never>?

    /// Start tracking all active and upcoming flights (within 6 hours).
    func startTracking(flights: [Flight], modelContext: ModelContext) {
        stopTracking()
        isTracking = true

        trackingTask = Task {
            while !Task.isCancelled {
                let now = Date.now
                let sixHoursFromNow = now.addingTimeInterval(6 * 3600)

                let relevant = flights.filter { flight in
                    flight.isActive ||
                    (flight.isUpcoming && flight.scheduledDeparture <= sixHoursFromNow)
                }

                for flight in relevant {
                    let oldStatus = flight.statusRaw
                    let oldDelay = flight.delayMinutes
                    let oldGate = flight.departureGate

                    await updateFlightStatus(flight)

                    // Fire notifications on changes
                    if flight.statusRaw != oldStatus {
                        await handleStatusChange(flight: flight, from: oldStatus)
                    }
                    if flight.delayMinutes != oldDelay && flight.delayMinutes > 0 {
                        ArcNotifications.notifyDelay(flight: flight)
                    }
                    if let newGate = flight.departureGate, newGate != oldGate {
                        ArcNotifications.notifyGateChange(flight: flight, newGate: newGate)
                    }

                    // Update Live Activity
                    await LiveActivityManager.shared.updateActivity(for: flight)

                    // Track live position for in-flight
                    if let icao24 = flight.aircraftICAO24, flight.isActive {
                        await updateLivePosition(flight, icao24: icao24)
                    }

                    // Check inbound for upcoming
                    if flight.isUpcoming {
                        await InboundMonitor.checkInbound(for: flight)
                    }
                }

                try? modelContext.save()

                // Poll at user-configured interval (default 60s)
                let interval = UserDefaults.standard.integer(forKey: "trackingInterval")
                let pollSeconds = interval > 0 ? interval : 60
                try? await Task.sleep(for: .seconds(pollSeconds))
            }
        }
    }

    func stopTracking() {
        trackingTask?.cancel()
        trackingTask = nil
        isTracking = false
    }

    // MARK: - Status Change Handler

    private func handleStatusChange(flight: Flight, from oldStatus: String) async {
        switch flight.statusRaw {
        case "active":
            LiveActivityManager.shared.startActivity(for: flight)
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
            flight.statusRaw = latest.status
            flight.delayMinutes = latest.delay ?? 0

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
        } catch {
            // Silently skip
        }
    }
}
