import Foundation
import WidgetKit

/// Syncs flight data to the App Group so home screen widgets can display it.
enum WidgetSync {

    static func sync(flights: [Flight]) {
        let widgetFlights = flights
            .filter { isWorthShowing($0) }
            .sorted { $0.scheduledDeparture < $1.scheduledDeparture }
            .prefix(5)
            .map(WidgetFlight.init)

        WidgetData.save(flights: Array(widgetFlights))
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// A cancelled or diverted trip is none of upcoming/active/landed, so it used
    /// to simply vanish from the widget — leaving a countdown to a flight that
    /// isn't happening as the last thing the user saw. Keep it until its
    /// scheduled arrival passes.
    static func isWorthShowing(_ flight: Flight, at now: Date = .now) -> Bool {
        flight.isUpcoming || flight.isActive || flight.isRecentlyLanded
            || ((flight.status == .cancelled || flight.status == .diverted)
                && flight.scheduledArrival > now.addingTimeInterval(-30 * 60))
    }
}

extension WidgetFlight {
    /// The App Group snapshot of a leg.
    ///
    /// Separate from `WidgetSync.sync` so it can be asserted on without an App
    /// Group: everything the widget is allowed to claim is decided here, and the
    /// widget can only be as honest as this mapping.
    init(_ flight: Flight) {
        self.init(
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
            // A delay figure only exists where the source reports one. A stale
            // number on a timetable leg would also shift the widget's countdown,
            // which targets the delay-adjusted time.
            delayMinutes: flight.reportsPunctuality ? flight.delayMinutes : 0,
            departureGate: flight.departureGate,
            progress: flight.progress,
            predictedDelayMinutes: flight.showsPrediction ? flight.predictedDelayMinutes : 0,
            // Without these two the widget can only speak about flights: a
            // saved train was told it was "In Flight" at a "Gate", and a ferry
            // wore the green On Time nobody published.
            mode: flight.mode,
            dataTier: flight.dataTier
        )
    }
}
