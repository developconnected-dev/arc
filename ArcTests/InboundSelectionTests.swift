import XCTest
@testable import Arc

final class InboundSelectionTests: XCTestCase {
    // Fractional seconds throughout — this is the real AeroDataBox/Worker wire
    // format ("2026-07-20T10:00:00.000Z"). Earlier versions of these fixtures
    // used clean non-fractional timestamps and passed despite a real parsing
    // bug in the production code path; realistic fixtures are the whole point.
    private func leg(_ number: String, from dep: String, to arr: String, arrScheduled: String, delay: Int? = nil) -> FlightAPIClient.FlightSearchResult {
        .init(flight_number: number, airline_name: "Swiss", airline_iata: "LX",
              dep_iata: dep, arr_iata: arr, dep_city: nil, arr_city: nil,
              dep_scheduled: "2026-07-20T10:00:00.000Z", arr_scheduled: arrScheduled,
              dep_actual: nil, arr_actual: nil,
              status: "landed", dep_gate: nil, dep_terminal: nil, arr_gate: nil,
              arr_terminal: nil, arr_baggage: nil, delay: delay,
              aircraft_type: nil, aircraft_registration: nil,
              dep_lat: nil, dep_lon: nil, arr_lat: nil, arr_lon: nil)
    }

    private let myDeparture = DateHelpers.parseAPIDate("2026-07-20T14:00:00.000Z")!

    func testPicksLegArrivingAtDepartureAirportBeforeMyDeparture() {
        let legs = [leg("LX9", from: "JFK", to: "ZRH", arrScheduled: "2026-07-20T12:00:00.000Z")]
        let picked = InboundSelection.selectInboundLeg(
            from: legs, excludingFlightNumber: "LX14", arrivingAt: "ZRH", before: myDeparture)
        XCTAssertEqual(picked?.flight_number, "LX9")
    }

    func testExcludesOwnFlightNumber() {
        let legs = [leg("LX14", from: "JFK", to: "ZRH", arrScheduled: "2026-07-20T12:00:00.000Z")]
        let picked = InboundSelection.selectInboundLeg(
            from: legs, excludingFlightNumber: "LX14", arrivingAt: "ZRH", before: myDeparture)
        XCTAssertNil(picked)
    }

    func testExcludesLegsAtWrongAirport() {
        let legs = [leg("LX9", from: "JFK", to: "LHR", arrScheduled: "2026-07-20T12:00:00.000Z")]
        let picked = InboundSelection.selectInboundLeg(
            from: legs, excludingFlightNumber: "LX14", arrivingAt: "ZRH", before: myDeparture)
        XCTAssertNil(picked)
    }

    func testExcludesLegsArrivingAfterMyDeparture() {
        // Lands at ZRH at 15:00 — but my flight left ZRH at 14:00, so this can't be my inbound aircraft.
        let legs = [leg("LX9", from: "JFK", to: "ZRH", arrScheduled: "2026-07-20T15:00:00.000Z")]
        let picked = InboundSelection.selectInboundLeg(
            from: legs, excludingFlightNumber: "LX14", arrivingAt: "ZRH", before: myDeparture)
        XCTAssertNil(picked)
    }

    func testPicksMostRecentAmongMultipleCandidates() {
        let legs = [
            leg("LX3", from: "LHR", to: "ZRH", arrScheduled: "2026-07-20T08:00:00.000Z"),
            leg("LX9", from: "JFK", to: "ZRH", arrScheduled: "2026-07-20T12:00:00.000Z"),   // most recent, still before 14:00
            leg("LX5", from: "CDG", to: "ZRH", arrScheduled: "2026-07-19T20:00:00.000Z"),
        ]
        let picked = InboundSelection.selectInboundLeg(
            from: legs, excludingFlightNumber: "LX14", arrivingAt: "ZRH", before: myDeparture)
        XCTAssertEqual(picked?.flight_number, "LX9")
    }

    func testReturnsNilWhenNoLegsProvided() {
        let picked = InboundSelection.selectInboundLeg(
            from: [], excludingFlightNumber: "LX14", arrivingAt: "ZRH", before: myDeparture)
        XCTAssertNil(picked)
    }
}
