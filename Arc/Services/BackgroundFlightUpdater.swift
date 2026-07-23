import Foundation
import SwiftData
import ActivityKit

/// Runs a dedicated loop that pushes Live Activity updates every 60 seconds.
/// Each update recalculates progress from Date.now, so the arc moves.
@MainActor
final class BackgroundFlightUpdater {
    static let shared = BackgroundFlightUpdater()

    private var updateTask: Task<Void, Never>?
    private var isRunning = false

    func start(modelContainer: ModelContainer) {
        guard !isRunning else { return }
        isRunning = true
        print("[Arc] BackgroundFlightUpdater started")

        updateTask = Task {
            let context = ModelContext(modelContainer)

            while !Task.isCancelled {
                do {
                    await pushUpdates(context: context)
                } catch {
                    print("[Arc] BackgroundFlightUpdater error: \(error)")
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func pushUpdates(context: ModelContext) async {
        let activities = Activity<FlightActivityAttributes>.activities
        print("[Arc] BackgroundFlightUpdater: \(activities.count) active Live Activities")

        guard !activities.isEmpty else { return }

        let descriptor = FetchDescriptor<Flight>()
        guard let flights = try? context.fetch(descriptor) else {
            print("[Arc] BackgroundFlightUpdater: failed to fetch flights")
            return
        }
        print("[Arc] BackgroundFlightUpdater: \(flights.count) flights in database")

        for activity in activities {
            let matchingFlight = flights.first(where: {
                $0.flightNumber == activity.attributes.flightNumber &&
                $0.departureIATA == activity.attributes.departureIATA
            })

            if let flight = matchingFlight {
                print("[Arc] BackgroundFlightUpdater: updating \(flight.flightNumber), progress=\(flight.progress)")
                await LiveActivityManager.shared.updateActivity(for: flight)
            } else {
                print("[Arc] BackgroundFlightUpdater: no match for \(activity.attributes.flightNumber) \(activity.attributes.departureIATA)")
                // Try to find by flight number only (departure IATA might differ due to how it was stored)
                if let flight = flights.first(where: { $0.flightNumber == activity.attributes.flightNumber }) {
                    print("[Arc] BackgroundFlightUpdater: found by number only, updating \(flight.flightNumber)")
                    await LiveActivityManager.shared.updateActivity(for: flight)
                }
            }
        }

        // Time-based status healing
        for flight in flights {
            let depTime = flight.actualDeparture ?? flight.scheduledDeparture.addingTimeInterval(Double(flight.delayMinutes) * 60)
            let arrTime = flight.estimatedArrival ?? flight.scheduledArrival

            if (flight.statusRaw == "scheduled" || flight.statusRaw == "boarding" || flight.statusRaw == "gateClosed") && Date.now >= depTime {
                print("[Arc] BackgroundFlightUpdater: healing \(flight.flightNumber) to active")
                flight.statusRaw = "active"
                try? context.save()
                await LiveActivityManager.shared.startActivity(for: flight)
            }

            if flight.statusRaw == "active" && Date.now >= arrTime {
                print("[Arc] BackgroundFlightUpdater: healing \(flight.flightNumber) to landed")
                flight.statusRaw = "landed"
                try? context.save()
                await LiveActivityManager.shared.endActivity(for: flight)
            }
        }
    }

    func stop() {
        updateTask?.cancel()
        updateTask = nil
        isRunning = false
    }
}
