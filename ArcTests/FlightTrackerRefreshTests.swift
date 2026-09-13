import XCTest
@testable import Arc

@MainActor
final class FlightTrackerRefreshTests: XCTestCase {
    func testBoardGateCanMoveAfterInitialPublication() {
        let flight = Flight(flightNumber: "LX17", date: .now)
        FlightTracker.applyBoardGate("A12", to: flight)
        FlightTracker.applyBoardGate("B7", to: flight)
        XCTAssertEqual(flight.departureGate, "B7")
        XCTAssertEqual(flight.previousDepartureGate, "A12")
        FlightTracker.applyBoardGate(nil, to: flight)
        XCTAssertEqual(flight.departureGate, "B7")
    }

    func testAircraftSwapWithoutAddressClearsOldTransponder() {
        for missing in [nil, ""] as [String?] {
            let flight = Flight(flightNumber: "LX17", date: .now)
            flight.aircraftICAO24 = "4b1234"
            FlightTracker.applyAircraftAddress(missing, swapped: true, to: flight)
            XCTAssertNil(flight.aircraftICAO24)
        }
    }

    func testSameAircraftKeepsAddressAndReplacementUsesNewAddress() {
        let flight = Flight(flightNumber: "LX17", date: .now)
        flight.aircraftICAO24 = "4b1234"
        FlightTracker.applyAircraftAddress(nil, swapped: false, to: flight)
        XCTAssertEqual(flight.aircraftICAO24, "4b1234")
        FlightTracker.applyAircraftAddress("4b5678", swapped: true, to: flight)
        XCTAssertEqual(flight.aircraftICAO24, "4b5678")
    }
}
