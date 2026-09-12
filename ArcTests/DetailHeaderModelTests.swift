import XCTest
@testable import Arc

/// The header's words and tints are decided in one place, so they can be
/// checked without a screen: what the pill says, what each tile's context
/// line says, and when a time is allowed to turn red.
@MainActor
final class DetailHeaderModelTests: XCTestCase {
    private func flight(status: FlightStatus = .scheduled, delay: Int = 0, hoursOut: Double = 5,
                        depTZ: String = "Europe/Zurich", arrTZ: String = "America/Chicago") -> Flight {
        let dep = Date.now.addingTimeInterval(hoursOut * 3600)
        let f = Flight(flightNumber: "LX8", date: dep)
        f.scheduledDeparture = dep
        f.scheduledArrival = dep.addingTimeInterval(9.5 * 3600)
        f.departureIATA = "ZRH"; f.arrivalIATA = "ORD"
        f.departureTZID = depTZ; f.arrivalTZID = arrTZ
        f.delayMinutes = delay
        f.status = status
        return f
    }

    func testAScheduledOnTimeFlightHasWhiteTimesAndAnOnTimePill() {
        let m = DetailHeaderModel(flight: flight())
        XCTAssertEqual(m.pill.text, "On Time")
        XCTAssertFalse(m.departure.moved)
        XCTAssertFalse(m.arrival.moved)
        XCTAssertNil(m.departure.scheduledIfMoved)
    }

    /// "On Time" is a quote from the operator, and Arc only starts asking
    /// the day before. Further out the pill says what the leg is — scheduled
    /// — in the grey the header already gave it; a published delay is still
    /// news at any distance.
    func testAFlightDaysAwayIsScheduledNotOnTime() {
        let far = DetailHeaderModel(flight: flight(hoursOut: 5 * 24))
        XCTAssertEqual(far.pill.text, "Scheduled")
        let tomorrow = DetailHeaderModel(flight: flight(hoursOut: 20))
        XCTAssertEqual(tomorrow.pill.text, "On Time")
        let moved = DetailHeaderModel(flight: flight(delay: 40, hoursOut: 5 * 24))
        XCTAssertEqual(moved.pill.text, "Delayed 40m")
    }

    func testADelayedDepartureIsMovedAndShowsTheScheduledTime() {
        let f = flight(delay: 25)
        let m = DetailHeaderModel(flight: f)
        XCTAssertTrue(m.departure.moved)
        XCTAssertEqual(m.departure.scheduledIfMoved, f.depTimeLocal)
        XCTAssertEqual(m.pill.text, "Delayed 25m")
    }

    func testArrivalContextIsYourTimeOnlyAcrossAZoneChange() {
        let away = DetailHeaderModel(flight: flight(arrTZ: "America/Chicago"))
        XCTAssertTrue(away.arrival.context.hasSuffix("your time"))
        let home = DetailHeaderModel(flight: flight(depTZ: TimeZone.current.identifier,
                                                    arrTZ: TimeZone.current.identifier))
        XCTAssertFalse(home.arrival.context.hasSuffix("your time"))
    }

    func testDepartureContextIsTheCountdownBeforeDeparture() {
        let m = DetailHeaderModel(flight: flight())
        XCTAssertTrue(m.departure.context.hasPrefix("in "), m.departure.context)
    }

    func testTheTripGroupCollapsesWhenNothingIsFilledIn() {
        let f = flight()
        XCTAssertTrue(TripGroup.isEmpty(f))
        f.seat = "14A"
        XCTAssertFalse(TripGroup.isEmpty(f))
    }
}
