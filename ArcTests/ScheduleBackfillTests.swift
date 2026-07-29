import XCTest
@testable import Arc

@MainActor
final class ScheduleBackfillTests: XCTestCase {
    private let now = DateHelpers.parseAPIDate("2026-07-29T12:00:00.000Z")!

    private func pending(dep: TimeInterval = 40 * 86400) -> Flight {
        let f = Flight(flightNumber: "A31653", date: now.addingTimeInterval(dep))
        f.awaitingSchedule = true
        return f
    }

    private func leg(dep: String, arr: String,
                     depTime: String = "2026-09-18T06:05:00.000Z",
                     arrTime: String = "2026-09-18T08:00:00.000Z") -> FlightAPIClient.FlightSearchResult {
        .init(flight_number: "A31653", airline_name: "Aegean Airlines", airline_iata: "A3",
              dep_iata: dep, arr_iata: arr, dep_city: "Athens", arr_city: "Munich",
              dep_scheduled: depTime, arr_scheduled: arrTime,
              dep_actual: nil, arr_actual: nil, status: "scheduled",
              dep_gate: "A12", dep_terminal: "2", arr_gate: nil, arr_terminal: nil,
              arr_baggage: nil, delay: 0, aircraft_type: "Airbus A320",
              aircraft_registration: "SX-DVA", aircraft_icao24: "468001",
              dep_lat: 37.93, dep_lon: 23.94, arr_lat: 48.35, arr_lon: 11.78)
    }

    // MARK: isDue

    func testNeverCheckedIsDue() {
        XCTAssertTrue(ScheduleBackfill.isDue(pending(), at: now))
    }

    func testNotDueAgainWithinADay() {
        let f = pending()
        f.lastScheduleCheckAt = now.addingTimeInterval(-23 * 3600)
        XCTAssertFalse(ScheduleBackfill.isDue(f, at: now))
        f.lastScheduleCheckAt = now.addingTimeInterval(-25 * 3600)
        XCTAssertTrue(ScheduleBackfill.isDue(f, at: now))
    }

    func testFlightsNotAwaitingAreLeftAlone() {
        let f = pending()
        f.awaitingSchedule = false
        XCTAssertFalse(ScheduleBackfill.isDue(f, at: now))
    }

    /// Past departure means the normal tracker owns it; there's nothing left
    /// to pre-fill and we shouldn't keep spending a lookup a day on it.
    func testDepartedFlightsStopBeingChecked() {
        XCTAssertFalse(ScheduleBackfill.isDue(pending(dep: -3600), at: now))
    }

    // MARK: bestLeg

    func testPrefersTheLegMatchingTheTypedRoute() {
        let f = pending()
        f.departureIATA = "ATH"; f.arrivalIATA = "MUC"
        let legs = [leg(dep: "ATH", arr: "LHR"), leg(dep: "ATH", arr: "MUC")]
        XCTAssertEqual(ScheduleBackfill.bestLeg(legs, matching: f)?.arr_iata, "MUC")
    }

    func testFallsBackToFirstLegWhenNoRouteWasTyped() {
        let legs = [leg(dep: "ATH", arr: "LHR"), leg(dep: "ATH", arr: "MUC")]
        XCTAssertEqual(ScheduleBackfill.bestLeg(legs, matching: pending())?.arr_iata, "LHR")
    }

    // MARK: apply

    func testApplyReplacesTypedDetailsAndClearsTheFlag() {
        let f = pending()
        f.seat = "12A"; f.bookingCode = "XY7Z9Q"; f.notes = "window"
        f.sharedWithIds = ["anna"]

        ScheduleBackfill.apply(leg(dep: "ATH", arr: "MUC"), to: f)

        XCTAssertEqual(f.departureIATA, "ATH")
        XCTAssertEqual(f.arrivalIATA, "MUC")
        XCTAssertEqual(f.airline, "Aegean Airlines")
        XCTAssertEqual(f.aircraftType, "Airbus A320")
        XCTAssertEqual(f.departureGate, "A12")
        XCTAssertEqual(f.scheduledDeparture, DateHelpers.parseAPIDate("2026-09-18T06:05:00.000Z"))
        XCTAssertFalse(f.awaitingSchedule, "found means stop looking")

        // The user's own fields are theirs.
        XCTAssertEqual(f.seat, "12A")
        XCTAssertEqual(f.bookingCode, "XY7Z9Q")
        XCTAssertEqual(f.notes, "window")
        XCTAssertEqual(f.sharedWithIds, ["anna"])
    }
}
