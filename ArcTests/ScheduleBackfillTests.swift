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
                     arrTime: String = "2026-09-18T08:00:00.000Z",
                     status: String = "scheduled",
                     delay: Int = 0) -> FlightAPIClient.FlightSearchResult {
        .init(flight_number: "A31653", airline_name: "Aegean Airlines", airline_iata: "A3",
              dep_iata: dep, arr_iata: arr, dep_city: "Athens", arr_city: "Munich",
              dep_scheduled: depTime, arr_scheduled: arrTime,
              dep_actual: nil, arr_actual: nil, status: status,
              dep_gate: "A12", dep_terminal: "2", arr_gate: nil, arr_terminal: nil,
              arr_baggage: nil, delay: delay, aircraft_type: "Airbus A320",
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

    // MARK: reschedule filed as two rows

    private func routed(_ f: Flight, depTime: String) {
        f.departureIATA = "ATH"; f.arrivalIATA = "MUC"
        f.scheduledDeparture = DateHelpers.parseAPIDate(depTime)!
    }

    /// The LX2146 pattern: the original operation marked cancelled, its
    /// replacement a second leg 25 minutes away on the same route. Closest
    /// by time alone returns the cancelled one — the stored time IS the
    /// original's — and the app then asserts a cancellation for a flight
    /// that operates.
    func testCancelledRowYieldsItsReFiling() {
        let f = pending()
        routed(f, depTime: "2026-09-18T06:05:00.000Z")
        let legs = [
            leg(dep: "ATH", arr: "MUC", status: "cancelled"),
            leg(dep: "ATH", arr: "MUC", depTime: "2026-09-18T06:30:00.000Z"),
        ]
        let best = ScheduleBackfill.bestLeg(legs, matching: f)
        XCTAssertEqual(best?.status, "scheduled")
        XCTAssertEqual(best?.dep_scheduled, "2026-09-18T06:30:00.000Z")
    }

    /// A shuttle's other rotation hours away is a different operation with
    /// its own passengers — the cancellation is real and must stay loud.
    func testShuttleRotationHoursAwayStaysCancelled() {
        let f = pending()
        routed(f, depTime: "2026-09-18T06:05:00.000Z")
        let legs = [
            leg(dep: "ATH", arr: "MUC", status: "cancelled"),
            leg(dep: "ATH", arr: "MUC", depTime: "2026-09-18T16:05:00.000Z"),
        ]
        XCTAssertEqual(ScheduleBackfill.bestLeg(legs, matching: f)?.status, "cancelled")
    }

    /// The provider's "likely cancelled" guess steps aside the same way.
    func testGuessFlaggedRowYieldsItsCleanSibling() {
        let f = pending()
        routed(f, depTime: "2026-09-18T06:05:00.000Z")
        var flagged = leg(dep: "ATH", arr: "MUC")
        flagged.cancel_uncertain = true
        let clean = leg(dep: "ATH", arr: "MUC", depTime: "2026-09-18T06:30:00.000Z")
        let best = ScheduleBackfill.bestLeg([flagged, clean], matching: f)
        XCTAssertEqual(best?.dep_scheduled, "2026-09-18T06:30:00.000Z")
        XCTAssertNotEqual(best?.cancel_uncertain, true)
    }

    // MARK: effectiveDelayMinutes

    func testEffectiveDelayCountsTheScheduleShift() {
        let stored = DateHelpers.parseAPIDate("2026-09-18T06:05:00.000Z")!
        // Same schedule: the leg's own delay, unchanged.
        XCTAssertEqual(ScheduleBackfill.effectiveDelayMinutes(
            of: leg(dep: "ATH", arr: "MUC", delay: 10), against: stored), 10)
        // Retimed 25 minutes later, on its own schedule: 25 late for the
        // person who planned around the stored time — and delays add.
        XCTAssertEqual(ScheduleBackfill.effectiveDelayMinutes(
            of: leg(dep: "ATH", arr: "MUC", depTime: "2026-09-18T06:30:00.000Z"), against: stored), 25)
        XCTAssertEqual(ScheduleBackfill.effectiveDelayMinutes(
            of: leg(dep: "ATH", arr: "MUC", depTime: "2026-09-18T06:30:00.000Z", delay: 10), against: stored), 35)
        // Moved earlier clamps to zero, the safe direction.
        XCTAssertEqual(ScheduleBackfill.effectiveDelayMinutes(
            of: leg(dep: "ATH", arr: "MUC", depTime: "2026-09-18T05:40:00.000Z"), against: stored), 0)
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
