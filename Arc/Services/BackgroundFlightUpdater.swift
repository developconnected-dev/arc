import Foundation
import SwiftData
import ActivityKit

/// Runs a dedicated loop that pushes Live Activity updates every 60 seconds.
/// Each update recalculates progress from Date.now, so the arc moves.
///
/// This loop only RENDERS — it never writes flight state. It used to run its
/// own time-based status healing against a second `ModelContext`, which
/// fought FlightTracker's healing in the main context (status flapping
/// active↔landed on alternating minutes) and skipped `handleStatusChange`,
/// so a landing it detected posted no notification and uploaded no track.
/// FlightTracker owns healing; this owns the 60-second repaint.
@MainActor
final class BackgroundFlightUpdater {
    static let shared = BackgroundFlightUpdater()

    private var updateTask: Task<Void, Never>?
    private var isRunning = false

    func start(modelContainer: ModelContainer) {
        guard !isRunning else { return }
        isRunning = true

        updateTask = Task {
            let context = ModelContext(modelContainer)

            while !Task.isCancelled {
                await pushUpdates(context: context)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func pushUpdates(context: ModelContext) async {
        // OWN activities only. A friend's card for the same flight number is
        // driven by FriendAlerts from the shared row — feeding it a local
        // flight's state would overwrite the friend's data with yours.
        let activities = Activity<FlightActivityAttributes>.activities
            .filter { $0.attributes.friendName == nil }
        guard !activities.isEmpty else { return }

        let descriptor = FetchDescriptor<Flight>()
        guard let flights = try? context.fetch(descriptor) else { return }

        for activity in activities {
            let flight = flights.first(where: {
                $0.flightNumber == activity.attributes.flightNumber &&
                $0.departureIATA == activity.attributes.departureIATA
            }) ?? flights.first(where: { $0.flightNumber == activity.attributes.flightNumber })
            if let flight, !flight.isDeleted {
                await LiveActivityManager.shared.updateActivity(for: flight)
            }
        }
    }

    func stop() {
        updateTask?.cancel()
        updateTask = nil
        isRunning = false
    }
}
