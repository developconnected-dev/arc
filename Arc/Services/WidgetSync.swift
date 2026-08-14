import Foundation
import WidgetKit

/// Syncs flight data to the App Group so home screen widgets can display it.
enum WidgetSync {

    static func sync(flights: [Flight]) {
        let widgetFlights = flights
            .filter { $0.isUpcoming || $0.isActive || $0.isRecentlyLanded }
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
