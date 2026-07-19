import Foundation
import SwiftData

/// Test/screenshot-only seeding. Runs only when the app is launched with the
/// `-seedDemo` argument and the store is empty. Never runs in normal use.
enum DemoSeed {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-seedDemo") }
    static var suppressPrompts: Bool { ProcessInfo.processInfo.arguments.contains("-uiNoPrompt") }

    static func seedIfRequested(into context: ModelContext, existing: [Flight]) {
        guard isRequested, existing.isEmpty else { return }
        let ref = ReferenceData.shared

        func make(_ number: String, _ dep: String, _ arr: String,
                  depOffsetH: Double, arrOffsetH: Double, status: String) -> Flight {
            let f = Flight(flightNumber: number, date: Date.now.addingTimeInterval(depOffsetH * 3600))
            f.airline = ref.airline(String(number.prefix(2)))?.name ?? ""
            f.airlineICAO = ref.airline(String(number.prefix(2)))?.icao ?? ""
            f.departureIATA = dep; f.arrivalIATA = arr
            if let a = ref.airport(dep) { f.departureCity = a.city; f.departureLat = a.lat; f.departureLon = a.lon }
            if let a = ref.airport(arr) { f.arrivalCity = a.city; f.arrivalLat = a.lat; f.arrivalLon = a.lon }
            f.scheduledDeparture = Date.now.addingTimeInterval(depOffsetH * 3600)
            f.scheduledArrival = Date.now.addingTimeInterval(arrOffsetH * 3600)
            f.statusRaw = status
            return f
        }

        // Active transatlantic flight with a live mid-Atlantic position.
        let active = make("LX14", "ZRH", "JFK", depOffsetH: -1.5, arrOffsetH: 7, status: "active")
        active.actualDeparture = Date.now.addingTimeInterval(-1.5 * 3600)
        active.aircraftType = "Airbus A330-300"
        active.liveLat = 55.0; active.liveLon = -25.0
        active.liveHeading = 285; active.liveAltitude = 10600; active.liveSpeed = 245
        active.liveUpdatedAt = .now

        let upcoming1 = make("GQ873", "HAM", "ATH", depOffsetH: 49 * 24, arrOffsetH: 49 * 24 + 4, status: "scheduled")
        upcoming1.airline = "Sky Express"
        let upcoming2 = make("LX1413", "BEG", "ZRH", depOffsetH: 17, arrOffsetH: 19, status: "scheduled")

        context.insert(active); context.insert(upcoming1); context.insert(upcoming2)
        try? context.save()
    }
}
