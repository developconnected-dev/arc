import Foundation
import WidgetKit

/// Syncs flight data to the App Group so home screen widgets can display it.
enum WidgetSync {

    static func sync(flights: [Flight]) {
        // What the App Group already holds — written by the app OR by the
        // widget's own refresh, which talks to the Worker on its own timeline
        // and therefore sometimes knows things this model hasn't heard yet.
        let previous = Dictionary(
            WidgetData.loadFlights().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let widgetFlights = flights
            .filter { isWorthShowing($0) }
            .sorted { $0.scheduledDeparture < $1.scheduledDeparture }
            .prefix(5)
            .map { WidgetFlight($0).mergingForward(over: previous[$0.id.uuidString]) }

        let changed = WidgetData.save(flights: Array(widgetFlights))
        // The widget refreshes the next flight's status on its own timeline
        // (WidgetRefresh) so it stays current with the app closed — it needs
        // to know which Worker to ask. Settings' override lives in standard
        // defaults, which the extension can't read; mirror it.
        WidgetData.sharedDefaults?.set(
            UserDefaults.standard.string(forKey: "apiEndpoint"), forKey: "apiEndpoint")
        // Only when there is something new to show. This runs every 60 s from
        // the tracking loop, and an unconditional reload spent the day's
        // WidgetKit budget on snapshots identical to the one already rendered.
        if changed { WidgetCenter.shared.reloadAllTimelines() }
    }

    /// A cancelled or diverted trip is none of upcoming/active/landed, so it used
    /// to simply vanish from the widget — leaving a countdown to a flight that
    /// isn't happening as the last thing the user saw. Keep it until its
    /// scheduled arrival passes.
    static func isWorthShowing(_ flight: Flight, at now: Date = .now) -> Bool {
        // A stuck-"active" leg hours past its arrival is history, not news.
        flight.isUpcoming
            || (flight.isActive && flight.effectiveArrival > now.addingTimeInterval(-45 * 60))
            || flight.isRecentlyLanded
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
            dataTier: flight.dataTier,
            departureTerminal: flight.departureTerminal,
            arrivalGate: flight.arrivalGate,
            arrivalTerminal: flight.arrivalTerminal,
            baggageClaim: flight.baggageClaim,
            estimatedArrival: flight.reportsPunctuality ? flight.estimatedArrival : nil,
            departureTZ: flight.depTimeZone.identifier,
            arrivalTZ: flight.arrTimeZone.identifier,
            updatedAt: flight.lastStatusUpdate,
            actualDeparture: flight.actualDeparture,
            estimatedTakeoff: flight.estimatedTakeoff,
            groundState: flight.groundStateRaw,
            groundObservedAt: flight.groundObservedAt,
            taxiStartedAt: flight.taxiStartedAt,
            lastSeenOnGround: flight.lastSeenOnGround,
            taxiPriorMinutes: flight.taxiPriorMinutes
        )
    }
}
