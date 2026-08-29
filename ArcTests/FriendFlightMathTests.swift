import XCTest
@testable import Arc

final class FriendFlightMathTests: XCTestCase {
    /// Wire-format fixtures: PostgREST returns timestamptz as ISO with offset.
    private func flight(_ number: String,
                        depScheduled: String, arrScheduled: String,
                        estimatedArrival: String? = nil,
                        status: String = "scheduled", delay: Int = 0) -> ArcSupabase.SharedFlight {
        .init(id: UUID().uuidString, user_id: "u1", flight_number: number,
              airline: "Swiss", departure_iata: "ZRH", arrival_iata: "JFK",
              departure_city: "Zürich", arrival_city: "New York",
              departure_lat: 47.46, departure_lon: 8.55,
              arrival_lat: 40.64, arrival_lon: -73.78,
              scheduled_departure: depScheduled, scheduled_arrival: arrScheduled,
              estimated_arrival: estimatedArrival,
              status: status, delay_minutes: delay,
              departure_gate: nil, arrival_gate: nil, baggage_claim: nil,
              live_lat: nil, live_lon: nil, progress: 0, updated_at: nil)
    }

    private let now = DateHelpers.parseAPIDate("2026-07-24T12:00:00.000Z")!

    // MARK: - Airborne / progress (clock wins over stale status)

    func testClockPastDepartureWithoutWitnessIsNotAirborne() {
        // Friend's device last synced before takeoff — status still says
        // "scheduled", clock is mid-flight. The clock is not a takeoff
        // witness: Takeoff unconfirmed, not In Air.
        let f = flight("LX14", depScheduled: "2026-07-24T10:00:00.000Z",
                       arrScheduled: "2026-07-24T18:00:00.000Z")
        XCTAssertFalse(FriendFlightMath.isAirborne(f, at: now))
        XCTAssertEqual(FriendFlightMath.departurePhase(f, at: now), .presumedAirborne)
        XCTAssertEqual(FriendFlightMath.chip(for: f, at: now).text, "UNCONFIRMED")
        XCTAssertEqual(FriendFlightMath.progress(f, at: now), 0.25, accuracy: 0.001)
    }

    func testLandedStatusBeatsClock() {
        // Landed early: status is authoritative on the ground.
        let f = flight("LX14", depScheduled: "2026-07-24T06:00:00.000Z",
                       arrScheduled: "2026-07-24T13:00:00.000Z", status: "landed")
        XCTAssertFalse(FriendFlightMath.isAirborne(f, at: now))
        XCTAssertEqual(FriendFlightMath.progress(f, at: now), 1)
    }

    func testDelayShiftsDepartureAndArrival() {
        // 30-min delay: at 12:00 a 11:45+30 departure hasn't happened yet.
        let f = flight("LX14", depScheduled: "2026-07-24T11:45:00.000Z",
                       arrScheduled: "2026-07-24T15:45:00.000Z", delay: 30)
        XCTAssertFalse(FriendFlightMath.isAirborne(f, at: now))
        XCTAssertEqual(FriendFlightMath.progress(f, at: now), 0)
    }

    // MARK: - Spotlight priority

    func testSpotlightPrefersAirborneOverSoonerUpcoming() {
        let flying = flight("LX1", depScheduled: "2026-07-24T10:00:00.000Z",
                            arrScheduled: "2026-07-24T14:00:00.000Z", status: "active")
        let upcoming = flight("LX2", depScheduled: "2026-07-24T13:00:00.000Z",
                              arrScheduled: "2026-07-24T17:00:00.000Z")
        let pick = FriendFlightMath.spotlight(from: [upcoming, flying], at: now)
        XCTAssertEqual(pick?.flight_number, "LX1")
    }

    func testSpotlightIgnoresUpcomingBeyond36Hours() {
        let nextWeek = flight("LX3", depScheduled: "2026-07-30T10:00:00.000Z",
                              arrScheduled: "2026-07-30T14:00:00.000Z")
        XCTAssertNil(FriendFlightMath.spotlight(from: [nextWeek], at: now))
    }

    func testSpotlightFallsBackToRecentlyLanded() {
        // Inside the 30-minute post-landing grace — still worth spotlighting,
        // because this is the window where the gate and the belt still matter.
        let landed = flight("LX4", depScheduled: "2026-07-24T05:45:00.000Z",
                            arrScheduled: "2026-07-24T11:45:00.000Z", status: "landed")
        let nextWeek = flight("LX5", depScheduled: "2026-07-30T10:00:00.000Z",
                              arrScheduled: "2026-07-30T14:00:00.000Z")
        let pick = FriendFlightMath.spotlight(from: [nextWeek, landed], at: now)
        XCTAssertEqual(pick?.flight_number, "LX4")
    }

    /// Past the grace it stops being news. Spotlighting a flight that landed
    /// four hours ago would keep a friend's finished trip pinned to the top of
    /// the screen for the rest of the day.
    func testSpotlightIgnoresLandingsPastTheGrace() {
        let landedLongAgo = flight("LX4", depScheduled: "2026-07-24T02:00:00.000Z",
                                   arrScheduled: "2026-07-24T08:00:00.000Z", status: "landed")
        XCTAssertNil(FriendFlightMath.spotlight(from: [landedLongAgo], at: now))
    }

    func testSpotlightSkipsCancelled() {
        let cancelled = flight("LX6", depScheduled: "2026-07-24T13:00:00.000Z",
                               arrScheduled: "2026-07-24T17:00:00.000Z", status: "cancelled")
        XCTAssertNil(FriendFlightMath.spotlight(from: [cancelled], at: now))
    }

    // MARK: - Chips

    func testChipLandsInWhileAirborne() {
        var f = flight("LX14", depScheduled: "2026-07-24T10:00:00.000Z",
                       arrScheduled: "2026-07-24T14:30:00.000Z", status: "active")
        f.actual_departure = "2026-07-24T10:12:00.000Z"
        let chip = FriendFlightMath.chip(for: f, at: now)
        XCTAssertEqual(chip.text, "LANDS IN 2H 30M")
        XCTAssertEqual(chip.kind, .inFlight)
    }

    func testChipCountdownBeforeDeparture() {
        let f = flight("LX14", depScheduled: "2026-07-24T20:55:00.000Z",
                       arrScheduled: "2026-07-25T02:00:00.000Z")
        let chip = FriendFlightMath.chip(for: f, at: now)
        XCTAssertEqual(chip.text, "IN 8H 55M")
        XCTAssertEqual(chip.kind, .countdown)
    }

    func testChipDelayedAndLanded() {
        let delayed = flight("LX14", depScheduled: "2026-07-24T13:00:00.000Z",
                             arrScheduled: "2026-07-24T17:00:00.000Z", delay: 25)
        XCTAssertEqual(FriendFlightMath.chip(for: delayed, at: now).kind, .delayed)

        let landed = flight("LX9", depScheduled: "2026-07-24T02:00:00.000Z",
                            arrScheduled: "2026-07-24T08:00:00.000Z", status: "landed")
        XCTAssertEqual(FriendFlightMath.chip(for: landed, at: now).text, "LANDED")
    }

    /// The estimated arrival (when the friend's device synced one) beats
    /// scheduled+delay for both progress and lands-in.
    func testEstimatedArrivalWins() {
        var f = flight("LX14", depScheduled: "2026-07-24T10:00:00.000Z",
                       arrScheduled: "2026-07-24T14:00:00.000Z",
                       estimatedArrival: "2026-07-24T13:00:00.000Z", status: "active")
        f.actual_departure = "2026-07-24T10:12:00.000Z"
        XCTAssertEqual(FriendFlightMath.chip(for: f, at: now).text, "LANDS IN 1H 0M")
        XCTAssertEqual(FriendFlightMath.progress(f, at: now), 2.0 / 3.0, accuracy: 0.001)
    }
}
