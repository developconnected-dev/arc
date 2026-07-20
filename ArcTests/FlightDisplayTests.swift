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
}
