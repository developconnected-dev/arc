import XCTest
@testable import Arc

@MainActor
final class FlightExporterTests: XCTestCase {
    private func flight() -> Flight {
        let f = Flight(flightNumber: "LX1413", date: Date(timeIntervalSince1970: 1_800_000_000))
        f.airline = "Swiss"
        f.departureIATA = "BEG"; f.arrivalIATA = "ZRH"
        f.departureCity = "Belgrade"; f.arrivalCity = "Zurich"
        f.scheduledArrival = f.scheduledDeparture.addingTimeInterval(2 * 3600)
        f.statusRaw = "scheduled"
        return f
    }

    func testExportMapsCoreFields() {
        let export = FlightExporter.export([flight()])
        XCTAssertEqual(export.count, 1)
        XCTAssertEqual(export.first?.flightNumber, "LX1413")
        XCTAssertEqual(export.first?.departureIATA, "BEG")
        XCTAssertEqual(export.first?.arrivalIATA, "ZRH")
    }

    func testWriteJSONFileProducesValidReadableJSON() throws {
        let url = FlightExporter.writeJSONFile([flight()])
        XCTAssertNotNil(url)
        let data = try Data(contentsOf: XCTUnwrap(url))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([FlightExporter.FlightExport].self, from: data)
        XCTAssertEqual(decoded.first?.flightNumber, "LX1413")
    }

    func testEmptyFlightsProducesEmptyArray() {
        XCTAssertTrue(FlightExporter.export([]).isEmpty)
    }
}
