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

/// The harbour and the station as witnesses. A flight's take-off is sensed
/// by GPS speed and the barometer; a ferry and a train have neither a
/// runway roll nor a cabin climb — but they do leave a place and arrive at
/// one, and iOS will say so for free: a geofence exit at the departure port
/// after the scheduled time IS the departure, an entry at the arrival port
/// IS the arrival. No GPS session, no barometer, nothing that warms a phone.
final class TransitFencePlannerTests: XCTestCase {
    private let dep = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { dep.addingTimeInterval(minutes * 60) }

    private func leg(_ id: UUID = UUID(), mode: TripMode = .sea, departed: Bool = false, arrived: Bool = false,
                     completed: Bool = false, arrivalMinutes: Double = 180,
                     depCoord: (Double, Double) = (37.44, 24.94),
                     arrCoord: (Double, Double) = (37.94, 23.64)) -> TransitFencePlanner.Leg {
        .init(id: id, mode: mode, offBlock: dep, effectiveArrival: at(arrivalMinutes),
              departed: departed, arrived: arrived, completed: completed,
              departure: .init(latitude: depCoord.0, longitude: depCoord.1),
              arrival: .init(latitude: arrCoord.0, longitude: arrCoord.1))
    }

    // MARK: - Which fences to arm

    func testAnUpcomingSailingArmsBothEnds() {
        let l = leg()
        let fences = TransitFencePlanner.fences(for: [l], now: at(-120))
        XCTAssertEqual(fences.map(\.kind), [.departure, .arrival])
        XCTAssertEqual(fences[0].flightId, l.id)
        XCTAssertEqual(fences[0].radius, TransitFencePlanner.harbourRadius)
        XCTAssertEqual(fences[1].center.latitude, 37.94, accuracy: 1e-9)
        XCTAssertTrue(fences[0].identifier.hasPrefix(TransitFencePlanner.identifierPrefix))
    }

    func testATrainRingsItsStationsMoreTightly() {
        let fences = TransitFencePlanner.fences(for: [leg(mode: .rail)], now: at(-60))
        XCTAssertEqual(fences.first?.radius, TransitFencePlanner.stationRadius)
    }

    func testAFlightIsNotATransitLeg() {
        XCTAssertTrue(TransitFencePlanner.fences(for: [leg(mode: .air)], now: at(-60)).isEmpty)
    }

    func testOnceDepartedOnlyTheArrivalFenceRemains() {
        let fences = TransitFencePlanner.fences(for: [leg(departed: true)], now: at(30))
        XCTAssertEqual(fences.map(\.kind), [.arrival])
    }

    func testACompletedOrLongPastLegArmsNothing() {
        XCTAssertTrue(TransitFencePlanner.fences(for: [leg(completed: true)], now: at(30)).isEmpty)
        XCTAssertTrue(TransitFencePlanner.fences(for: [leg()], now: at(180 + 61)).isEmpty)
    }

    func testALegDaysAwayWaitsItsTurn() {
        XCTAssertTrue(TransitFencePlanner.fences(for: [leg()], now: at(-37 * 60)).isEmpty)
    }

    func testAPortWithoutCoordinatesCannotBeRinged() {
        XCTAssertTrue(TransitFencePlanner.fences(for: [leg(depCoord: (0, 0))], now: at(-60)).isEmpty)
    }

    /// iOS allows twenty monitored regions; the airport wake takes two.
    func testAtMostTwoLegsAreRinged() {
        let legs = (0..<4).map { _ in leg() }
        XCTAssertEqual(TransitFencePlanner.fences(for: legs, now: at(-60)).count, 4)
    }

    // MARK: - What an event means

    func testLeavingThePortAfterTheScheduledTimeIsTheDeparture() {
        let l = leg()
        XCTAssertEqual(TransitFencePlanner.verdict(for: .exit, of: .departure, leg: l, at: at(8)), .departed)
    }

    func testLeavingThePortAFewMinutesEarlyStillCounts() {
        XCTAssertEqual(TransitFencePlanner.verdict(for: .exit, of: .departure, leg: leg(), at: at(-5)), .departed)
    }

    func testLeavingThePortLongBeforeDepartureIsJustLeavingThePort() {
        XCTAssertEqual(TransitFencePlanner.verdict(for: .exit, of: .departure, leg: leg(), at: at(-90)), .none)
    }

    func testAnExitLongAfterTheVoyageEndedIsNoise() {
        XCTAssertEqual(TransitFencePlanner.verdict(for: .exit, of: .departure, leg: leg(), at: at(180 + 90)), .none)
    }

    func testArrivingAtTheDestinationPortIsTheArrival() {
        XCTAssertEqual(TransitFencePlanner.verdict(for: .entry, of: .arrival, leg: leg(departed: true), at: at(170)), .arrived)
    }

    func testTheDestinationFenceBeforeTheVoyageCouldBeOverIsNotAnArrival() {
        // A port passed on the way, or the traveller's own home port used
        // as the arrival of a later leg: far too early to be this arrival.
        XCTAssertEqual(TransitFencePlanner.verdict(for: .entry, of: .arrival, leg: leg(departed: true), at: at(30)), .none)
    }

    func testAnArrivalNeedsADeparture() {
        XCTAssertEqual(TransitFencePlanner.verdict(for: .entry, of: .arrival, leg: leg(), at: at(170)), .none)
    }

    func testTheWrongEventForAFenceMeansNothing() {
        XCTAssertEqual(TransitFencePlanner.verdict(for: .entry, of: .departure, leg: leg(), at: at(5)), .none)
        XCTAssertEqual(TransitFencePlanner.verdict(for: .exit, of: .arrival, leg: leg(departed: true), at: at(170)), .none)
    }
}
