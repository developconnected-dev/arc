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
        // One register per mode on every surface (TripMode.inTransitTitle):
        // the list, the widget and the friends feed may not disagree.
        for (mode, moving, arrived) in [(TripMode.air, "In Air", "Landed"),
                                        (.rail, "En Route", "Arrived"),
                                        (.sea, "At Sea", "Arrived")] {
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

    // MARK: - Tracking the thing that was actually booked

    func testHandAddedTrainIsNotLeftWaitingOnAnAirlineSchedule() {
        // ScheduleBackfill exists for a flight filed before its schedule was
        // published. A train's schedule will never appear in an airline feed, so
        // this asked the same question once a day forever and always got no.
        let train = leg(.rail, tier: .manual)
        train.awaitingSchedule = true
        XCTAssertFalse(ScheduleBackfill.isDue(train, at: .now))

        let ferry = leg(.sea, tier: .manual, number: "BLUE STAR DELOS")
        ferry.awaitingSchedule = true
        XCTAssertFalse(ScheduleBackfill.isDue(ferry, at: .now))
    }

    func testHandAddedFlightStillWaitsForItsSchedule() {
        let flight = leg(.air, tier: .manual, number: "LX14")
        flight.awaitingSchedule = true
        XCTAssertTrue(ScheduleBackfill.isDue(flight, at: .now))
    }

    /// The Worker builds this key too, and the two must agree exactly or
    /// `/rail/reresolve` returns null and the train silently stops refreshing.
    /// The expected string was printed by `railServiceKey()` in
    /// backend/src/transit.ts for the ICE 373 trip in backend/test/transit.test.ts.
    func testRailKeyIsByteIdenticalToTheWorkers() {
        let departure = Date(timeIntervalSince1970: 1_785_919_020)   // 2026-08-05T08:37:00Z
        XCTAssertEqual(
            RailServiceKey.make(operatorName: "DB Fernverkehr AG", service: "ICE 373",
                                boardingStopID: "de-DELFI_de:11000:900003201",
                                scheduledDeparture: departure),
            "db fernverkehr ag|ICE373|de-DELFI_de:11000:900003201|2026-08-05T08:37")
    }

    func testRailKeyIgnoresTheSpacingAFeedHappensToUse() {
        let departure = Date(timeIntervalSince1970: 1_785_919_020)
        XCTAssertEqual(
            RailServiceKey.make(operatorName: " DB Fernverkehr AG ", service: " ICE  373 ",
                                boardingStopID: " de-DELFI_de:11000:900003201 ",
                                scheduledDeparture: departure),
            RailServiceKey.make(operatorName: "DB Fernverkehr AG", service: "ICE 373",
                                boardingStopID: "de-DELFI_de:11000:900003201",
                                scheduledDeparture: departure))
    }

    func testAPortIsDatedInItsOwnZoneNotThroughTheAirportTable() {
        // 22:40 UTC on the 5th is 01:40 on the 6th in Athens: a sailing asked for
        // on the wrong date comes back empty, and the leg stops refreshing.
        let sailing = Date(timeIntervalSince1970: 1_785_969_600)   // 2026-08-05T22:40:00Z
        XCTAssertEqual(
            DateHelpers.apiDate(sailing, in: TimeZone(identifier: "Europe/Athens")!),
            "2026-08-06")
        XCTAssertEqual(DateHelpers.apiDate(sailing, in: TimeZone(identifier: "UTC")!),
                       "2026-08-05")
    }

    // MARK: - The widget must not be more confident than the app

    func testTimetableLegReachesTheWidgetWithoutAPunctualityClaim() {
        // The app already refuses to paint this leg green; the widget was still
        // doing it, because the snapshot didn't carry the tier at all.
        let ferry = leg(.sea, tier: .scheduled, number: "BLUE STAR DELOS")
        let snapshot = WidgetFlight(ferry)
        XCTAssertEqual(snapshot.dataTier, .scheduled)
        XCTAssertFalse(snapshot.reportsPunctuality)
        XCTAssertEqual(snapshot.statusText(phase: .upcoming), "Timetable")
    }

    func testAStrayDelayIsNotSyncedForALegThatReportsNone() {
        let ferry = leg(.sea, tier: .scheduled, delay: 25)
        XCTAssertEqual(WidgetFlight(ferry).delayMinutes, 0,
                       "a delay nobody published must not shift the widget countdown")
    }

    func testTrainIsNotDescribedAsAFlightInTheWidget() {
        let train = leg(.rail, tier: .live)
        train.status = .active
        let snapshot = WidgetFlight(train)
        XCTAssertEqual(snapshot.mode, .rail)
        XCTAssertEqual(snapshot.statusText(phase: .inFlight), "En Route")
        XCTAssertEqual(snapshot.mode.boardingPointLabel, "Platform")
        train.status = .landed
        XCTAssertEqual(WidgetFlight(train).terminalLabel, "Arrived")
    }

    func testFlightSnapshotIsUnchanged() {
        let flight = leg(.air, tier: .live, number: "LX14", delay: 20)
        let snapshot = WidgetFlight(flight)
        XCTAssertTrue(snapshot.reportsPunctuality)
        XCTAssertEqual(snapshot.delayMinutes, 20)
        XCTAssertEqual(snapshot.statusText(phase: .upcoming), "Delayed 20m")
        XCTAssertEqual(snapshot.statusText(phase: .inFlight), "In Air")
    }

    func testCancelledSailingStillEarnsItsRedInTheWidget() {
        let ferry = leg(.sea, tier: .scheduled)
        ferry.status = .cancelled
        let snapshot = WidgetFlight(ferry)
        XCTAssertTrue(snapshot.isDisrupted)
        XCTAssertTrue(snapshot.reportsPunctuality,
                      "a cancellation is reported, so the colour is earned")
        XCTAssertEqual(snapshot.terminalLabel, "Cancelled")
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

/// A timetable has no notion of "underway": Ferryhopper and the rail board
/// answer "scheduled" for a crossing that cast off an hour ago. Stamping
/// that onto the leg every poll undid the clock's own "active" thirty
/// minutes at a time — the row, the card and the map flapped between
/// departing and at sea for the whole voyage.
final class TransitStatusMergeTests: XCTestCase {
    func testATimetableCannotUndoAnUnderwayLeg() {
        XCTAssertEqual(FlightTracker.transitStatus(local: .active, provider: .scheduled), .active)
        XCTAssertEqual(FlightTracker.transitStatus(local: .landed, provider: .scheduled), .landed)
    }

    func testTheProviderStillWinsWhenItKnowsSomething() {
        XCTAssertEqual(FlightTracker.transitStatus(local: .active, provider: .cancelled), .cancelled)
        XCTAssertEqual(FlightTracker.transitStatus(local: .active, provider: .landed), .landed)
        XCTAssertEqual(FlightTracker.transitStatus(local: .scheduled, provider: .active), .active)
        XCTAssertEqual(FlightTracker.transitStatus(local: .scheduled, provider: .scheduled), .scheduled)
    }
}
