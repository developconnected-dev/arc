import XCTest
@testable import Arc

/// What-if scenarios for the wake ladder's pure brain. Each test is a
/// moment iOS hands the app a wake — a geofence entry, a hold tick, a
/// grant — and asserts where the code leads: sensors, hold, or sleep.
final class TakeoffWakePlannerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    private func cand(_ id: UUID = UUID(), offBlockIn: TimeInterval,
                      windowLength: TimeInterval = 2 * 3600,
                      departed: Bool = false) -> TakeoffWakePlanner.Candidate {
        .init(id: id,
              offBlock: now.addingTimeInterval(offBlockIn),
              windowEnd: now.addingTimeInterval(offBlockIn + windowLength),
              departed: departed)
    }

    func testArrivingAtTheAirportEarlyHoldsUntilTheWindow() {
        // Geofence entry two hours before off-block: keep the process alive,
        // don't burn full sensors yet.
        XCTAssertEqual(TakeoffWakePlanner.call([cand(offBlockIn: 2 * 3600)], now: now), .hold)
    }

    func testInsideTheWindowStartsSensors() {
        let id = UUID()
        XCTAssertEqual(TakeoffWakePlanner.call([cand(id, offBlockIn: 5 * 60)], now: now),
                       .sensors(id))
    }

    func testExactlyAtWindowOpenStartsSensors() {
        // now == offBlock − lead: the boundary belongs to the window.
        let id = UUID()
        XCTAssertEqual(
            TakeoffWakePlanner.call(
                [cand(id, offBlockIn: TakeoffWakePlanner.windowLead)], now: now),
            .sensors(id))
    }

    func testJustBeforeTheWindowStillHolds() {
        // One minute shy of the lead: hold, not sensors — the next tick flips.
        XCTAssertEqual(
            TakeoffWakePlanner.call(
                [cand(offBlockIn: TakeoffWakePlanner.windowLead + 60)], now: now),
            .hold)
    }

    func testFlightTomorrowSleeps() {
        // A wake at the airport the evening before (picking someone up):
        // nothing to hold for, let iOS reclaim the process.
        XCTAssertEqual(TakeoffWakePlanner.call([cand(offBlockIn: 20 * 3600)], now: now), .sleep)
    }

    func testDepartedFlightSleeps() {
        XCTAssertEqual(
            TakeoffWakePlanner.call([cand(offBlockIn: 5 * 60, departed: true)], now: now),
            .sleep)
    }

    func testExpiredWindowSleeps() {
        // Off-block five hours ago, window closed three hours ago — the
        // takeoff either happened unobserved or the flight is a mess the
        // provider owns; a wake changes nothing.
        XCTAssertEqual(TakeoffWakePlanner.call([cand(offBlockIn: -5 * 3600)], now: now), .sleep)
    }

    func testConnectionAfterLandingHoldsForTheNextLeg() {
        // Landed leg 1 standing inside leg 2's geofence, layover 90 minutes:
        // the post-landing re-judge must yield a hold, because the fence's
        // entry event already fired and will never fire again.
        let leg1 = cand(offBlockIn: -4 * 3600, departed: true)
        let leg2 = cand(offBlockIn: 90 * 60)
        XCTAssertEqual(TakeoffWakePlanner.call([leg1, leg2], now: now), .hold)
    }

    func testEarliestDueFlightWins() {
        // Two flights both inside their windows (a rebooked mess): the one
        // boarding first gets the sensors.
        let first = UUID(), second = UUID()
        XCTAssertEqual(
            TakeoffWakePlanner.call(
                [cand(first, offBlockIn: 5 * 60), cand(second, offBlockIn: 10 * 60)], now: now),
            .sensors(first))
    }

    func testHoldHorizonIsStrict() {
        // Exactly three hours out: not yet worth the power.
        XCTAssertEqual(
            TakeoffWakePlanner.call(
                [cand(offBlockIn: TakeoffWakePlanner.holdHorizon)], now: now),
            .sleep)
    }
}
