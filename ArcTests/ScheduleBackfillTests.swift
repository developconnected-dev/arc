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

    /// The off-route fallback exists for hand-typed flights (a mis-picked
    /// airport corrected by the airline's filing) and must be OPTED INTO.
    /// Live tracking passes false: an off-route pick there would stamp a
    /// different leg's status and route onto the tracked flight.
    func testOffRouteFallbackOnlyWhenAllowed() {
        // Legs on the same day as the typed departure — the fallback is
        // bounded to 24h so a different day's leg can never rewrite a route.
        let iso = ISO8601DateFormatter()
        let f = pending(dep: 3600)
        let near = iso.string(from: f.scheduledDeparture.addingTimeInterval(1800))
        let legs = [leg(dep: "ATH", arr: "LHR", depTime: near),
                    leg(dep: "ATH", arr: "MUC", depTime: near)]
        XCTAssertEqual(ScheduleBackfill.bestLeg(legs, matching: f, allowRouteChange: true)?.arr_iata, "LHR")
        XCTAssertNil(ScheduleBackfill.bestLeg(legs, matching: f), "off-route needs opting in")
        // A whole day away is a different journey, not a corrected airport.
        let farAway = pending(dep: 3 * 86400)
        XCTAssertNil(ScheduleBackfill.bestLeg(legs, matching: farAway, allowRouteChange: true))
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
