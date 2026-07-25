import XCTest
@testable import Arc

final class FriendAlertsTests: XCTestCase {
    private func flight(_ id: String, _ number: String,
                        dep: String, arr: String,
                        status: String = "scheduled", delay: Int = 0) -> ArcSupabase.SharedFlight {
        .init(id: id, user_id: "u1", flight_number: number,
              airline: "Swiss", departure_iata: "ZRH", arrival_iata: "LIS",
              departure_city: "Zurich", arrival_city: "Lisbon",
              departure_lat: 47.46, departure_lon: 8.55,
              arrival_lat: 38.77, arrival_lon: -9.13,
              scheduled_departure: dep, scheduled_arrival: arr,
              estimated_arrival: nil, status: status, delay_minutes: delay,
              departure_gate: nil, arrival_gate: nil, baggage_claim: nil,
              live_lat: nil, live_lon: nil, progress: 0, updated_at: nil)
    }

    private let anna = ArcSupabase.ArcUser(
        id: "anna", display_name: "Anna", handle: nil, avatar_url: nil,
        home_airport: nil, nationality: nil)

    private let now = DateHelpers.parseAPIDate("2026-07-24T12:00:00.000Z")!

    func testTakeoffTransitionFires() {
        // Baseline saw it upcoming; the clock now places it mid-flight.
        let f = flight("f1", "LX2084", dep: "2026-07-24T11:30:00.000Z", arr: "2026-07-24T14:00:00.000Z")
        let events = FriendAlerts.events(
            baseline: ["f1": "upcoming|0"],
            flights: [(anna, f)], levels: [:], at: now)
        XCTAssertEqual(events.map(\.kind), [.tookOff])
        XCTAssertEqual(events.first?.friendName, "Anna")
    }

    func testLandingTransitionFires() {
        let f = flight("f1", "LX2084", dep: "2026-07-24T08:00:00.000Z",
                       arr: "2026-07-24T11:00:00.000Z", status: "landed")
        let events = FriendAlerts.events(
            baseline: ["f1": "airborne|0"],
            flights: [(anna, f)], levels: [:], at: now)
        XCTAssertEqual(events.map(\.kind), [.landed])
    }

    func testDelayGrowthFiresOnlyPastThreshold() {
        let f = flight("f1", "LX2084", dep: "2026-07-24T15:00:00.000Z",
                       arr: "2026-07-24T18:00:00.000Z", delay: 25)
        // +25 vs baseline 10 = +15 → fires with the NEW total.
        let events = FriendAlerts.events(
            baseline: ["f1": "upcoming|10"],
            flights: [(anna, f)], levels: [:], at: now)
        XCTAssertEqual(events.map(\.kind), [.delayed(25)])

        // +14 → silent.
        let small = flight("f1", "LX2084", dep: "2026-07-24T15:00:00.000Z",
                           arr: "2026-07-24T18:00:00.000Z", delay: 24)
        XCTAssertTrue(FriendAlerts.events(
            baseline: ["f1": "upcoming|10"],
            flights: [(anna, small)], levels: [:], at: now).isEmpty)
    }

    func testOffLevelMutesEverything() {
        let f = flight("f1", "LX2084", dep: "2026-07-24T11:30:00.000Z", arr: "2026-07-24T14:00:00.000Z")
        let events = FriendAlerts.events(
            baseline: ["f1": "upcoming|0"],
            flights: [(anna, f)], levels: ["anna": .off], at: now)
        XCTAssertTrue(events.isEmpty)
    }

    /// A flight never seen before records silently — connecting with a friend
    /// mid-trip (or a fresh baseline after reinstall) must not spam.
    func testFirstSightIsSilent() {
        let f = flight("f1", "LX2084", dep: "2026-07-24T11:30:00.000Z", arr: "2026-07-24T14:00:00.000Z")
        XCTAssertTrue(FriendAlerts.events(
            baseline: [:], flights: [(anna, f)], levels: [:], at: now).isEmpty)
    }

    func testBaselineValueEncodesPhaseAndDelay() {
        let f = flight("f1", "LX2084", dep: "2026-07-24T11:30:00.000Z",
                       arr: "2026-07-24T14:00:00.000Z", delay: 30)
        XCTAssertEqual(FriendAlerts.baselineValue(f, at: now), "airborne|30")
    }
}
