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

    // MARK: - Where a tapped friend alert lands

    /// A friend's landing alert carried NO `userInfo` at all, so the tap
    /// handler's `guard let destination` bailed and the notification opened
    /// whatever the app happened to show last — in testing, the reader's own
    /// unrelated flight. And there was nowhere for it to go even if it had:
    /// both existing destinations resolve against `allFlights`, the reader's
    /// OWN SwiftData flights, and a friend's flight is not among them.
    func testAFriendAlertRoutesToTheFriendsFlightItNames() {
        let info: [AnyHashable: Any] = [ArcOpenFlightInfo.friendId: "3f2b1c00-0000-4000-8000-000000000001"]
        XCTAssertEqual(ArcDeepLink.destination(fromNotificationUserInfo: info),
                       .friendFlight(id: "3f2b1c00-0000-4000-8000-000000000001"))
    }

    /// The reader's own alerts must keep going where they always went — a
    /// friend id is an ADDITION, never a reinterpretation of the old keys.
    func testAnOwnFlightAlertStillRoutesToTheOwnFlight() {
        let id = UUID()
        let info: [AnyHashable: Any] = [ArcOpenFlightInfo.id: id.uuidString]
        XCTAssertEqual(ArcDeepLink.destination(fromNotificationUserInfo: info), .flight(id: id))
    }

    /// A notification carrying nothing routable still returns nil rather than
    /// guessing at a flight.
    func testAnAlertWithNothingRoutableGoesNowhere() {
        XCTAssertNil(ArcDeepLink.destination(fromNotificationUserInfo: [:]))
        XCTAssertNil(ArcDeepLink.destination(fromNotificationUserInfo: [ArcOpenFlightInfo.friendId: ""]))
    }

    /// What `FriendAlerts` actually attaches — the seam the bug lived in.
    func testPostedFriendAlertsCarryTheirFlight() {
        let info = FriendAlerts.userInfo(forFlightId: "3f2b1c00-0000-4000-8000-000000000001")
        XCTAssertEqual(ArcDeepLink.destination(fromNotificationUserInfo: info),
                       .friendFlight(id: "3f2b1c00-0000-4000-8000-000000000001"))
    }
}

// MARK: - …and the tap has to survive the app not being running yet

/// The half of the friend-alert fix that did not work, and why.
///
/// Tapping a friend's alert on a COLD launch reached the Friends tab and
/// stopped there. Routing was fine; the drain was the problem. FriendsView
/// asked to open the parked flight with `.task(id: store.pendingFlightId)`,
/// which fires when the view appears and when the id changes — and on a cold
/// launch both of those had already happened by the time the view existed. The
/// one attempt ran against a feed that was still empty, found nothing, and
/// nothing ever looked again. Warm, the feed was already loaded, which is
/// exactly why it worked every time it was tested with the app open.
///
/// The parked id is only half the question. The other half is whether the feed
/// carries it yet, so the key has to move when the answer does.
@MainActor
final class PendingFriendFlightDrainTests: XCTestCase {

    /// THE regression: an empty feed and a loaded one must not key the same.
    func testTheDrainIsRetriedOnceTheFeedArrives() {
        let cold = FriendsListView.pendingOpenKey(wanted: "abc", feedIds: [], pastIds: [])
        let loaded = FriendsListView.pendingOpenKey(wanted: "abc", feedIds: ["abc"], pastIds: [])
        XCTAssertNotEqual(cold, loaded, "a cold launch gets exactly one attempt without this")
    }

    /// A landing that has aged out of the live feed still opens.
    func testAFlightInThePastFeedCountsToo() {
        XCTAssertNotEqual(FriendsListView.pendingOpenKey(wanted: "abc", feedIds: [], pastIds: []),
                          FriendsListView.pendingOpenKey(wanted: "abc", feedIds: [], pastIds: ["abc"]))
    }

    /// Presence, not contents: every friend's feed refresh would otherwise
    /// re-run the drain, and a refresh is not a tap.
    func testAnUnrelatedFeedChangeIsNotARetry() {
        XCTAssertEqual(FriendsListView.pendingOpenKey(wanted: "abc", feedIds: ["abc", "x"], pastIds: []),
                       FriendsListView.pendingOpenKey(wanted: "abc", feedIds: ["abc", "x", "y"], pastIds: ["z"]))
    }

    /// Two taps in a row, at two different flights, are two different asks.
    func testADifferentTapIsADifferentAsk() {
        XCTAssertNotEqual(FriendsListView.pendingOpenKey(wanted: "abc", feedIds: ["abc", "def"], pastIds: []),
                          FriendsListView.pendingOpenKey(wanted: "def", feedIds: ["abc", "def"], pastIds: []))
    }

    /// Nothing parked is one stable key, so an idle Friends tab never re-runs
    /// the drain as its feed comes and goes.
    func testNothingParkedNeverChangesKey() {
        XCTAssertEqual(FriendsListView.pendingOpenKey(wanted: nil, feedIds: [], pastIds: []),
                       FriendsListView.pendingOpenKey(wanted: nil, feedIds: ["a"], pastIds: ["b"]))
    }
}
