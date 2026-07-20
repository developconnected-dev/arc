import Foundation

/// Exports the user's flight log as JSON — the "Export Flight Data" action in
/// Settings. Personal data portability: your own flights, in a plain format
/// you can keep, inspect, or import elsewhere.
enum FlightExporter {
    struct FlightExport: Codable {
        let flightNumber: String
        let airline: String
        let departureIATA: String
        let arrivalIATA: String
        let departureCity: String
        let arrivalCity: String
        let scheduledDeparture: Date
        let scheduledArrival: Date
        let status: String
        let delayMinutes: Int
        let aircraftType: String?
        let aircraftRegistration: String?
        let distanceKm: Double
        let notes: String
    }

    static func export(_ flights: [Flight]) -> [FlightExport] {
        flights.map { f in
            FlightExport(
                flightNumber: f.flightNumber, airline: f.airline,
                departureIATA: f.departureIATA, arrivalIATA: f.arrivalIATA,
                departureCity: f.departureCity, arrivalCity: f.arrivalCity,
                scheduledDeparture: f.scheduledDeparture, scheduledArrival: f.scheduledArrival,
                status: f.statusRaw, delayMinutes: f.delayMinutes,
                aircraftType: f.aircraftType, aircraftRegistration: f.aircraftRegistration,
                distanceKm: f.distanceKm, notes: f.notes
            )
        }
    }

    /// Writes all flights to a JSON file in the temp directory and returns its
    /// URL, ready to hand to a `ShareLink`.
    static func writeJSONFile(_ flights: [Flight]) -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(export(flights)) else { return nil }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("arc-flights-export.json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
