import XCTest
@testable import Arc

/// Trains and ferries share the flight model, so the risks are all of one kind:
/// a leg that isn't a flight being described, coloured or tracked as if it were.
@MainActor
final class TripModeTests: XCTestCase {

    private func leg(_ mode: TripMode, tier: DataTier,
                     number: String = "ICE 373", delay: Int = 0) -> Flight {
        let f = Flight(flightNumber: number, date: .now.addingTimeInterval(3600))
        f.mode = mode
        f.dataTier = tier
        f.scheduledArrival = f.scheduledDeparture.addingTimeInterval(7200)
        f.delayMinutes = delay
        return f
    }

    // MARK: - Honest status

    func testFerryNeverClaimsToBeOnTime() {
        // No Mediterranean operator publishes a revised time per sailing, so a
        // green "On Time" would be Arc asserting something nobody told it.
        let ferry = leg(.sea, tier: .scheduled, number: "BLUE STAR DELOS")
        XCTAssertFalse(ferry.reportsPunctuality)
        XCTAssertNotEqual(ferry.statusText, "On Time")
        XCTAssertEqual(ferry.statusText, "Timetable")
    }

    func testFlightStillSaysOnTime() {
        let flight = leg(.air, tier: .live, number: "LX14")
        XCTAssertTrue(flight.reportsPunctuality)
        XCTAssertEqual(flight.statusText, "On Time")
    }

    func testLiveTrainReportsItsDelay() {
        let train = leg(.rail, tier: .live, delay: 16)
        XCTAssertEqual(train.statusText, "Delayed 16m")
        XCTAssertTrue(train.isDelayed)
    }

    func testTimetableOnlyLegIsNotCountedAsDelayed() {
        // delayMinutes is 0 on a timetable leg, but the guard must not depend on
        // that — a stray value must not light the row red on no evidence.
        let ferry = leg(.sea, tier: .scheduled)
        ferry.delayMinutes = 25
        XCTAssertFalse(ferry.isDelayed)
    }

    func testCancellationIsLoudInEveryTier() {
        let ferry = leg(.sea, tier: .scheduled)
        ferry.status = .cancelled
        XCTAssertEqual(ferry.statusText, "Cancelled")
        XCTAssertTrue(ferry.isDelayed)
    }

    func testOperatorNoticeReplacesTheTimetableLabel() {
        let ferry = leg(.sea, tier: .scheduled)
        ferry.disruptionNote = "Cancelled due to adverse weather"
        XCTAssertEqual(ferry.statusText, "Check Operator Notice")
    }

    // MARK: - Vocabulary

    func testTrainsDoNotLandAndFerriesAreNotInTheAir() {
        for (mode, moving, arrived) in [(TripMode.air, "In Air", "Landed"),
                                        (.rail, "En Route", "Arrived"),
                                        (.sea, "En Route", "Arrived")] {
            let f = leg(mode, tier: .live)
            f.status = .active
            XCTAssertEqual(f.statusText, moving, "\(mode) in transit")
            f.status = .landed
            XCTAssertEqual(f.statusText, arrived, "\(mode) arrived")
        }
    }

    func testBoardingPointIsNamedForItsMode() {
        XCTAssertEqual(leg(.air, tier: .live).boardingPointLabel, "Gate")
        XCTAssertEqual(leg(.rail, tier: .live).boardingPointLabel, "Platform")
        XCTAssertEqual(leg(.sea, tier: .scheduled).boardingPointLabel, "Berth")
    }

    // MARK: - Identifiers that must not cross modes

    func testVesselMMSINeverReachesTheAircraftTracker() {
        // An MMSI is nine digits where an ICAO24 is six hex. Sent to the
        // aircraft lookup it returns a position for something else, or nothing,
        // and reports no error either way.
        let ferry = leg(.sea, tier: .scheduled)
        ferry.vesselMMSI = "237012345"
        ferry.aircraftICAO24 = "4b1815"
        XCTAssertEqual(ferry.livePositionSource, .ais(mmsi: "237012345"))
    }

    func testFlightStillTracksByICAO24() {
        let flight = leg(.air, tier: .live, number: "LX14")
        flight.aircraftICAO24 = "4b1815"
        XCTAssertEqual(flight.livePositionSource, .openSky(icao24: "4b1815"))
    }

    func testTrainsHaveNoLivePositionSource() {
        // No free Europe-wide feed publishes live train positions; the map arc
        // is driven by timetable progress instead.
        XCTAssertNil(leg(.rail, tier: .live).livePositionSource)
    }

    func testMalformedMMSIIsRefusedRatherThanGuessed() {
        let ferry = leg(.sea, tier: .scheduled)
        ferry.vesselMMSI = "abc"
        XCTAssertNil(ferry.livePositionSource)
        ferry.vesselMMSI = "1234"
        XCTAssertNil(ferry.livePositionSource)
    }

    func testAirlineCodeIsNotScrapedOffAVesselName() {
        // "BLUE STAR DELOS" would yield "BL" and pull an unrelated carrier's
        // logo onto a ferry.
        XCTAssertEqual(leg(.sea, tier: .scheduled, number: "BLUE STAR DELOS").airlineCode, "")
        XCTAssertEqual(leg(.rail, tier: .live, number: "ICE 373").airlineCode, "")
        XCTAssertEqual(leg(.air, tier: .live, number: "LX14").airlineCode, "LX")
    }

    // MARK: - Time zones

    func testStoredZoneBeatsTheAirportTable() {
        // "PIR" is a port, but a three-letter code is exactly what the airport
        // lookup expects — so without the stored zone a Piraeus sailing could
        // silently inherit an airport's timezone from another continent.
        let ferry = leg(.sea, tier: .scheduled)
        ferry.departureIATA = "PIR"
        ferry.departureTZID = "Europe/Athens"
        XCTAssertEqual(ferry.depTimeZone.identifier, "Europe/Athens")
    }

    func testEachEndKeepsItsOwnZoneAcrossABorder() {
        let train = leg(.rail, tier: .live)
        train.departureTZID = "Europe/Berlin"
        train.arrivalTZID = "Europe/Zurich"
        XCTAssertEqual(train.depTimeZone.identifier, "Europe/Berlin")
        XCTAssertEqual(train.arrTimeZone.identifier, "Europe/Zurich")
    }

    func testFlightsStillFallBackToTheAirportTable() {
        let flight = leg(.air, tier: .live, number: "LX14")
        flight.departureIATA = "ZRH"
        XCTAssertNil(flight.departureTZID)
        XCTAssertEqual(flight.depTimeZone.identifier, "Europe/Zurich")
    }

    // MARK: - Migration safety

    func testAnExistingFlightMigratesAsAFlight() {
        // Rows written before trains existed carry no mode. They were all
        // provider-tracked flights, and must keep behaving as such.
        let old = Flight(flightNumber: "LX14", date: .now)
        XCTAssertEqual(old.mode, .air)
        XCTAssertEqual(old.dataTier, .live)
        XCTAssertTrue(old.reportsPunctuality)
    }
}
