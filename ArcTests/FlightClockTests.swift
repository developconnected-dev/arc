import XCTest
@testable import Arc

/// Absolute remaining time for until-gate / until-landing / relative
/// countdowns. VY8462 BCN→LIS (CEST → WEST, 1h offset) jumped between ~30m
/// and ~1h30m when a writer mixed airport-local wall clocks — or applied
/// the departure delay to the scheduled arrival — into the countdown target.
final class FlightClockTests: XCTestCase {
    private let lisbon = TimeZone(identifier: "Europe/Lisbon")!
    private let madrid = TimeZone(identifier: "Europe/Madrid")!
    private let utc = TimeZone(identifier: "UTC")!

    /// 20:18 LIS = 19:18Z. Device 21:02 CEST = 19:02Z. Remaining 16m.
    private let eta = Date(timeIntervalSince1970: 1_788_376_680)      // 2026-09-02 19:18:00Z
    private let now = Date(timeIntervalSince1970: 1_788_375_720)      // 2026-09-02 19:02:00Z
    private let scheduledArr = Date(timeIntervalSince1970: 1_788_377_700) // 20:35 LIS = 19:35Z
    private let revisedArr = Date(timeIntervalSince1970: 1_788_375_600)   // 20:00 LIS = 19:00Z
    private let jumpNow = Date(timeIntervalSince1970: 1_788_373_800)      // 20:30 CEST = 18:30Z

    func testUntilLandingIsTheEpochGap() {
        XCTAssertEqual(FlightClock.secondsUntil(eta, now: now), 16 * 60, accuracy: 0.5)
        XCTAssertEqual(FlightClock.compactUntil(eta, now: now), "16m")
    }

    /// Wall-clock labels differ by exactly the CEST/WEST hour. Remaining
    /// must not. A formatter that subtracted HH:mm in the device zone from
    /// HH:mm in Lisbon would flip by 60 minutes when the phone stayed on
    /// Barcelona time.
    func testUntilLandingStableAcrossDisplayTimeZones() {
        XCTAssertEqual(FlightClock.hhmm(eta, in: lisbon), "20:18")
        XCTAssertEqual(FlightClock.hhmm(eta, in: madrid), "21:18")
        XCTAssertEqual(FlightClock.hhmm(eta, in: utc), "19:18")

        let remaining = FlightClock.secondsUntil(eta, now: now)
        for zone in [lisbon, madrid, utc] {
            // Display-only: changing the formatter zone must not be an input
            // to the countdown. The same instant stays 16 minutes out.
            _ = FlightClock.hhmm(eta, in: zone)
            _ = FlightClock.hhmm(now, in: zone)
            XCTAssertEqual(FlightClock.secondsUntil(eta, now: now), remaining, accuracy: 0.5)
            XCTAssertEqual(remaining, 16 * 60, accuracy: 0.5)
        }
    }

    /// The VY8462 Live Activity jump: 30m to the provider estimate vs 90m
    /// to schedule + departure delay. Hero arrival must keep the estimate.
    func testHeroArrivalDoesNotApplyDepartureDelayWhenAnEstimateExists() {
        let hero = FlightClock.heroArrival(
            scheduled: scheduledArr, delayMinutes: 25, estimated: revisedArr)
        XCTAssertEqual(hero, revisedArr)
        XCTAssertEqual(FlightClock.secondsUntil(hero, now: jumpNow), 30 * 60, accuracy: 0.5)

        let invented = scheduledArr.addingTimeInterval(25 * 60)
        XCTAssertEqual(FlightClock.secondsUntil(invented, now: jumpNow), 90 * 60, accuracy: 0.5)
        XCTAssertNotEqual(hero, invented)
    }

    func testHeroArrivalFallsBackToSchedulePlusDelayOnlyWithoutAnEstimate() {
        let hero = FlightClock.heroArrival(
            scheduled: scheduledArr, delayMinutes: 25, estimated: nil)
        XCTAssertEqual(hero, scheduledArr.addingTimeInterval(25 * 60))
    }

    func testConfirmedLandingBeatsTheEstimate() {
        let actual = Date(timeIntervalSince1970: 1_788_376_920) // 20:22 LIS
        XCTAssertEqual(
            FlightClock.heroArrival(
                scheduled: scheduledArr, delayMinutes: 25,
                estimated: revisedArr, actual: actual),
            actual)
    }
}
