import Foundation
import ActivityKit

/// Manages Live Activities for active flights.
/// Shows flight progress on lock screen and Dynamic Island.
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var activeActivities: [String: Activity<FlightActivityAttributes>] = [:]

    func startActivity(for flight: Flight) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = FlightActivityAttributes(
            flightNumber: flight.flightNumber,
            departureIATA: flight.departureIATA,
            arrivalIATA: flight.arrivalIATA,
            airline: flight.airline
        )

        let state = FlightActivityAttributes.ContentState(
            status: flight.statusRaw,
            progress: flight.progress,
            departureTime: flight.actualDeparture ?? flight.scheduledDeparture,
            arrivalTime: flight.estimatedArrival ?? flight.scheduledArrival,
            delayMinutes: flight.delayMinutes,
            gate: flight.departureGate
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
            activeActivities[flight.id.uuidString] = activity
        } catch {
            print("[Arc] Failed to start Live Activity: \(error)")
        }
    }

    func updateActivity(for flight: Flight) async {
        guard let activity = activeActivities[flight.id.uuidString] else { return }

        let state = FlightActivityAttributes.ContentState(
            status: flight.statusRaw,
            progress: flight.progress,
            departureTime: flight.actualDeparture ?? flight.scheduledDeparture,
            arrivalTime: flight.estimatedArrival ?? flight.scheduledArrival,
            delayMinutes: flight.delayMinutes,
            gate: flight.departureGate
        )

        let content = ActivityContent(state: state, staleDate: nil)
        nonisolated(unsafe) let act = activity
        await act.update(content)
    }

    func endActivity(for flight: Flight) async {
        guard let activity = activeActivities[flight.id.uuidString] else { return }
        let flightId = flight.id.uuidString

        let finalState = FlightActivityAttributes.ContentState(
            status: "landed",
            progress: 1.0,
            departureTime: flight.actualDeparture ?? flight.scheduledDeparture,
            arrivalTime: flight.actualArrival ?? flight.scheduledArrival,
            delayMinutes: flight.delayMinutes,
            gate: flight.arrivalGate
        )

        let content = ActivityContent(state: finalState, staleDate: nil)
        nonisolated(unsafe) let act = activity
        await act.end(content, dismissalPolicy: .after(.now + 3600))
        activeActivities.removeValue(forKey: flightId)
    }
}

// FlightActivityAttributes is in Shared/FlightActivityAttributes.swift
