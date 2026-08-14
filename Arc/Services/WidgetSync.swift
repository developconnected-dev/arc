import Foundation
import WidgetKit

/// Syncs flight data to the App Group so home screen widgets can display it.
enum WidgetSync {

    static func sync(flights: [Flight]) {
        let widgetFlights = flights
            .filter {
                // A cancelled or diverted trip is none of upcoming/active/landed,
                // so it used to simply vanish from the widget — leaving a
                // countdown to a flight that isn't happening as the last thing
                // the user saw. Keep it until its scheduled arrival passes.
                $0.isUpcoming || $0.isActive || $0.isRecentlyLanded
                    || ((($0.status == .cancelled) || ($0.status == .diverted))
                        && $0.scheduledArrival > Date.now.addingTimeInterval(-30 * 60))
            }
            .sorted { $0.scheduledDeparture < $1.scheduledDeparture }
            .prefix(5)
            .map { flight in
                WidgetFlight(
                    id: flight.id.uuidString,
                    flightNumber: flight.flightNumber,
                    airline: flight.airline,
                    departureIATA: flight.departureIATA,
                    arrivalIATA: flight.arrivalIATA,
                    departureCity: flight.departureCity,
                    arrivalCity: flight.arrivalCity,
                    scheduledDeparture: flight.scheduledDeparture,
                    scheduledArrival: flight.scheduledArrival,
                    status: flight.statusRaw,
                    delayMinutes: flight.delayMinutes,
                    departureGate: flight.departureGate,
                    progress: flight.progress,
                    predictedDelayMinutes: flight.showsPrediction ? flight.predictedDelayMinutes : 0
                )
            }

        WidgetData.save(flights: Array(widgetFlights))
        WidgetCenter.shared.reloadAllTimelines()
    }
}
