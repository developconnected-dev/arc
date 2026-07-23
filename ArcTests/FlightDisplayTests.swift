import XCTest
@testable import Arc

@MainActor
final class FlightDisplayTests: XCTestCase {
    private func makeFlight(delay: Int = 0, status: FlightStatus = .scheduled) -> Flight {
        let dep = Date(timeIntervalSince1970: 1_800_000_000)   // fixed instant
        let f = Flight(flightNumber: "LX1413", date: dep)
        f.scheduledDeparture = dep
        f.scheduledArrival = dep.addingTimeInterval(2 * 3600)
        f.delayMinutes = delay
        f.status = status
        return f
    }

    func testEffectiveDepartureFallsBackToScheduledWhenNoDelay() {
        let f = makeFlight(delay: 0)
        XCTAssertEqual(f.effectiveDeparture, f.scheduledDeparture)
    }

    /// Regression: a flight coming back from live search only ever sets
    /// `delayMinutes`, never `actualDeparture` — effectiveDeparture must still
    /// reflect the delay, or the whole Detail screen silently reads "On Time".
    func testEffectiveDepartureDerivesFromDelayMinutesWhenNoActualTimeSet() {
        let f = makeFlight(delay: 45)
        XCTAssertNil(f.actualDeparture)
        XCTAssertEqual(f.effectiveDeparture, f.scheduledDeparture.addingTimeInterval(45 * 60))
        XCTAssertTrue(f.departureChanged)
    }

    func testEffectiveDeparturePrefersExplicitActualTimeOverDelayMinutes() {
        let f = makeFlight(delay: 45)
        let explicit = f.scheduledDeparture.addingTimeInterval(50 * 60)
        f.actualDeparture = explicit
        XCTAssertEqual(f.effectiveDeparture, explicit)
    }

    func testEffectiveArrivalDerivesFromDelayMinutesWhenNoActualOrEstimatedTimeSet() {
        let f = makeFlight(delay: 20)
        XCTAssertEqual(f.effectiveArrival, f.scheduledArrival.addingTimeInterval(20 * 60))
    }

    func testDepartureStatusTextReflectsDelay() {
        let f = makeFlight(delay: 65)
        XCTAssertEqual(f.departureStatusText, "1h 5m Late")
    }

    func testDepartureStatusTextOnTimeWhenNoDelay() {
        let f = makeFlight(delay: 0)
        XCTAssertEqual(f.departureStatusText, "On Time")
    }

    func testBannerColorIsLateWhenDelayed() {
        let f = makeFlight(delay: 30)
        XCTAssertEqual(f.bannerColor, ArcTheme.late)
    }

    func testBannerColorIsOnTimeWhenNotDelayed() {
        let f = makeFlight(delay: 0)
        XCTAssertEqual(f.bannerColor, ArcTheme.onTime)
    }

    // MARK: isRecentlyLanded — uses relative Date.now offsets, not the fixed
    // `makeFlight` instant above (which is a fixed future date, not "recent").

    private func landedFlight(minutesAgo: Double) -> Flight {
        let f = Flight(flightNumber: "LX1413", date: .now)
        f.scheduledDeparture = .now.addingTimeInterval(-3 * 3600)
        f.scheduledArrival = .now.addingTimeInterval(-minutesAgo * 60)
        f.actualArrival = f.scheduledArrival
        f.status = .landed
        return f
    }

    func testRecentlyLandedTrueJustAfterLanding() {
        XCTAssertTrue(landedFlight(minutesAgo: 5).isRecentlyLanded)
    }

    func testRecentlyLandedFalseAfter30Minutes() {
        XCTAssertFalse(landedFlight(minutesAgo: 31).isRecentlyLanded)
    }

    func testRecentlyLandedFalseForNonLandedStatus() {
        let f = landedFlight(minutesAgo: 5)
        f.status = .active
        XCTAssertFalse(f.isRecentlyLanded)
    }

    func testMyFlightsCardShowsLandedLabelDuringGracePeriod() {
        let f = landedFlight(minutesAgo: 5)
        XCTAssertEqual(f.cardTopRight, "Landed")
        XCTAssertEqual(f.cardTopRightColor, f.accentColor)
    }
}

final class DateHelpersTests: XCTestCase {
    /// Regression: entering "16:22" for a flight departing some other city must
    /// record 16:22 in THAT city's timezone, not 16:22 in the device's timezone.
    ///
    /// A real DatePicker writes its bound Date using the device's own
    /// `Calendar.current` — so "what the user typed" is modelled here the same
    /// way: build the instant with `Calendar.current` (whatever zone this test
    /// happens to run in), not a hardcoded zone, so the test is honest about
    /// what the function actually receives and stays valid on any machine.
    func testReinterpretWallClockPreservesClockDigitsInTargetZone() {
        let typed = Calendar.current.date(from: DateComponents(
            year: 2026, month: 7, day: 20, hour: 16, minute: 22))!

        let zurich = TimeZone(identifier: "Europe/Zurich")!
        let result = DateHelpers.reinterpretWallClock(typed, asLocalTo: zurich)

        var zurichCal = Calendar(identifier: .gregorian)
        zurichCal.timeZone = zurich
        let comps = zurichCal.dateComponents([.hour, .minute], from: result)
        XCTAssertEqual(comps.hour, 16)
        XCTAssertEqual(comps.minute, 22)
    }

    func testReinterpretWallClockNoOpWhenTimeZoneNil() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(DateHelpers.reinterpretWallClock(now, asLocalTo: nil), now)
    }

    /// Regression: AeroDataBox timestamps always include fractional seconds
    /// (the Worker's `toISO()` round-trips through JS `Date.toISOString()`,
    /// which always produces ".sssZ"). A formatter built with only
    /// `.withInternetDateTime` silently fails on this — the earlier
    /// InboundSelection/AddFlightView tests all used clean non-fractional
    /// fixtures and passed despite the real bug, which is exactly why this
    /// needs a realistic fixture, not a convenient one.
    func testParseAPIDateHandlesRealAeroDataBoxFormat() {
        let d = DateHelpers.parseAPIDate("2026-07-20T11:05:00.000Z")
        XCTAssertNotNil(d)
        XCTAssertEqual(d, ISO8601DateFormatter().date(from: "2026-07-20T11:05:00Z"))
    }

    func testParseAPIDateStillHandlesPlainFormat() {
        XCTAssertNotNil(DateHelpers.parseAPIDate("2026-07-20T11:05:00Z"))
    }

    func testParseAPIDateNilForEmptyOrNil() {
        XCTAssertNil(DateHelpers.parseAPIDate(""))
        XCTAssertNil(DateHelpers.parseAPIDate(nil))
    }
}

final class FlightStatusHealTests: XCTestCase {
    func testHealPassesThroughKnownRawValue() {
        XCTAssertEqual(FlightStatus.heal(rawValue: "landed", scheduledArrival: .now), .landed)
    }

    /// Regression: before the Worker normalized AeroDataBox's vocabulary,
    /// `statusRaw` could be "expected"/"arrived"/etc. — neither `isUpcoming`
    /// nor `isCompleted` matches those, so the flight vanished from every
    /// list while still rendering on the Passport globe (route rendering
    /// doesn't filter by status). heal() is the safety net for exactly that.
    func testHealFallsBackToScheduledForFutureUnknownStatus() {
        let future = Date.now.addingTimeInterval(3600)
        XCTAssertEqual(FlightStatus.heal(rawValue: "expected", scheduledArrival: future), .scheduled)
    }

    func testHealFallsBackToLandedForPastUnknownStatus() {
        let past = Date.now.addingTimeInterval(-3600)
        XCTAssertEqual(FlightStatus.heal(rawValue: "arrived", scheduledArrival: past), .landed)
    }
}

@MainActor
final class FlightUpcomingTests: XCTestCase {
    private func flight(status: FlightStatus, departureOffset: TimeInterval) -> Flight {
        let f = Flight(flightNumber: "LX1413", date: .now.addingTimeInterval(departureOffset))
        f.scheduledDeparture = .now.addingTimeInterval(departureOffset)
        f.status = status
        return f
    }

    func testUpcomingTrueForScheduledFlightInTheFuture() {
        XCTAssertTrue(flight(status: .scheduled, departureOffset: 3600).isUpcoming)
    }

    /// Regression: a flight still marked .scheduled after its own scheduled
    /// departure time has passed — the overwhelmingly common case for any
    /// delayed flight, since the real airline hasn't reported "departed" yet
    /// even though the original schedule instant has ticked over — must stay
    /// isUpcoming. Previously isUpcoming also required scheduledDeparture in
    /// the future, so this flight satisfied neither isUpcoming nor isActive:
    /// FlightTracker's relevant-to-poll filter excluded it, so it could never
    /// be checked again to learn it eventually went active, and the same
    /// condition gated My Flights/map visibility — the flight vanishing "the
    /// moment it takes off" for any flight with even a few minutes of delay.
    func testUpcomingStaysTrueForScheduledFlightPastItsOwnDepartureTime() {
        XCTAssertTrue(flight(status: .scheduled, departureOffset: -900).isUpcoming)
    }

    func testUpcomingFalseOnceActive() {
        XCTAssertFalse(flight(status: .active, departureOffset: -900).isUpcoming)
    }

    func testUpcomingFalseOnceLanded() {
        XCTAssertFalse(flight(status: .landed, departureOffset: -3 * 3600).isUpcoming)
    }

    func testUpcomingIncludesBoardingAndGateClosed() {
        XCTAssertTrue(flight(status: .boarding, departureOffset: 900).isUpcoming)
        XCTAssertTrue(flight(status: .gateClosed, departureOffset: 300).isUpcoming)
    }
}

@MainActor
final class BoardingDisplayTests: XCTestCase {
    private func flight(status: FlightStatus) -> Flight {
        let f = Flight(flightNumber: "LX1413", date: .now.addingTimeInterval(1800))
        f.scheduledDeparture = .now.addingTimeInterval(1800)
        f.scheduledArrival = .now.addingTimeInterval(1800 + 2 * 3600)
        f.status = status
        return f
    }

    /// Regression: boarding fell through statusText's default branch, so the
    /// card read "Departs On Time" while passengers were already boarding.
    func testBoardingShowsAsStandaloneLabel() {
        XCTAssertEqual(flight(status: .boarding).statusText, "Boarding")
        XCTAssertEqual(flight(status: .boarding).cardTopRight, "Boarding")
    }

    func testGateClosedShowsAsStandaloneLabelInUrgentColor() {
        let f = flight(status: .gateClosed)
        XCTAssertEqual(f.cardTopRight, "Gate Closed")
        XCTAssertEqual(f.cardTopRightColor, ArcTheme.late)
    }
}

@MainActor
final class FlightTrackPointTests: XCTestCase {
    private func makeFlight() -> Flight {
        Flight(flightNumber: "LX14", date: .now)
    }

    func testAppendStoresAndRoundTripsPoints() {
        let f = makeFlight()
        f.appendTrackPoint(lat: 47.46, lon: 8.55, altitude: 3000)
        f.appendTrackPoint(lat: 48.30, lon: 7.20, altitude: 10600)
        XCTAssertEqual(f.trackPoints.count, 2)
        XCTAssertEqual(f.trackPoints[1].lat, 48.30, accuracy: 0.0001)
        XCTAssertEqual(f.trackPoints[1].altitude, 10600)
    }

    /// A position within 2 km of the last breadcrumb must be dropped —
    /// otherwise a plane holding/taxiing spams hundreds of near-identical
    /// points into storage.
    func testAppendDeduplicatesNearbyPoints() {
        let f = makeFlight()
        f.appendTrackPoint(lat: 47.4600, lon: 8.5500, altitude: nil)
        f.appendTrackPoint(lat: 47.4601, lon: 8.5502, altitude: nil)   // ~15 m away
        XCTAssertEqual(f.trackPoints.count, 1)
    }
}

final class WidgetFlightTests: XCTestCase {
    private func widgetFlight(status: String, depOffset: TimeInterval, delay: Int = 0) -> WidgetFlight {
        WidgetFlight(
            id: "t", flightNumber: "LX1413", airline: "Swiss",
            departureIATA: "BEG", arrivalIATA: "ZRH",
            departureCity: "Belgrade", arrivalCity: "Zurich",
            scheduledDeparture: .now.addingTimeInterval(depOffset),
            scheduledArrival: .now.addingTimeInterval(depOffset + 2 * 3600),
            status: status, delayMinutes: delay, departureGate: nil, progress: 0)
    }

    /// Regression: the widget's isUpcoming had the same dead zone the app
    /// model did — a delayed flight past its original scheduled time (not yet
    /// confirmed departed) vanished from the widget right at boarding time.
    func testWidgetUpcomingSurvivesPassingScheduledTime() {
        XCTAssertTrue(widgetFlight(status: "scheduled", depOffset: -900, delay: 20).isUpcoming)
    }

    func testWidgetUpcomingIncludesBoarding() {
        XCTAssertTrue(widgetFlight(status: "boarding", depOffset: 600).isUpcoming)
    }

    func testWidgetEffectiveDepartureReflectsDelay() {
        let f = widgetFlight(status: "scheduled", depOffset: 3600, delay: 30)
        XCTAssertEqual(f.effectiveDeparture.timeIntervalSince(f.scheduledDeparture), 1800, accuracy: 1)
    }
}
