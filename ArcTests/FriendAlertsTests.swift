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
        // Baseline saw it upcoming; a SOURCE now calls the leg active.
        let f = flight("f1", "LX2084", dep: "2026-07-24T11:30:00.000Z",
                       arr: "2026-07-24T14:00:00.000Z", status: "active")
        let events = FriendAlerts.events(
            baseline: ["f1": "upcoming|0"],
            flights: [(anna, f)], levels: [:], at: now)
        XCTAssertEqual(events.map(\.kind), [.tookOff])
        XCTAssertEqual(events.first?.friendName, "Anna")
    }

    /// The clock is not a takeoff witness. "Anna is in the air ✈️" used to
    /// fire the moment the gate time passed — a push asserting a takeoff
    /// nobody reported, while she could still be sitting in a ground hold.
    func testClockAloneFiresNoTakeoffPush() {
        let f = flight("f1", "LX2084", dep: "2026-07-24T11:30:00.000Z",
                       arr: "2026-07-24T14:00:00.000Z")   // status still "scheduled"
        let events = FriendAlerts.events(
            baseline: ["f1": "upcoming|0"],
            flights: [(anna, f)], levels: [:], at: now)
        XCTAssertTrue(events.isEmpty)
        // The baseline stays "upcoming" too, so the witness fires the
        // transition when it lands — late, not never.
        XCTAssertTrue(FriendAlerts.baselineValue(f, at: now).hasPrefix("upcoming|"))
        var confirmed = f
        confirmed.actual_departure = "2026-07-24T11:41:00.000Z"
        let late = FriendAlerts.events(
            baseline: ["f1": FriendAlerts.baselineValue(f, at: now)],
            flights: [(anna, confirmed)], levels: [:], at: now)
        XCTAssertEqual(late.map(\.kind), [.tookOff])
    }

    /// Landing is a fact only the source states; the clock crossing the
    /// scheduled arrival is not it.
    func testClockAloneFiresNoLandedPush() {
        let f = flight("f1", "LX2084", dep: "2026-07-24T08:00:00.000Z",
                       arr: "2026-07-24T11:00:00.000Z", status: "active")
        let events = FriendAlerts.events(
            baseline: ["f1": "airborne|0"],
            flights: [(anna, f)], levels: [:], at: now)   // an hour past the ETA
        XCTAssertTrue(events.isEmpty)
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
        // The WITNESSED phase, not the clock's: past the gate time with the
        // status still "scheduled", the baseline holds "upcoming" so the
        // eventual confirmation can still fire the takeoff alert.
        let unwitnessed = flight("f1", "LX2084", dep: "2026-07-24T11:30:00.000Z",
                                 arr: "2026-07-24T14:00:00.000Z", delay: 30)
        XCTAssertEqual(FriendAlerts.baselineValue(unwitnessed, at: now), "upcoming|30")
        let witnessed = flight("f1", "LX2084", dep: "2026-07-24T11:30:00.000Z",
                               arr: "2026-07-24T14:00:00.000Z", status: "active", delay: 30)
        XCTAssertEqual(FriendAlerts.baselineValue(witnessed, at: now), "airborne|30")
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

// MARK: - Which APNs host this install's tokens actually belong to

/// `#if DEBUG` was answering a question it cannot see.
///
/// The APNs host a device token belongs to is decided by the `aps-environment`
/// entitlement, which comes from the SIGNING PROFILE. `#if DEBUG` is a build
/// configuration. Those agree for the two builds anyone means to make — a
/// Debug run (development profile, sandbox token) and a TestFlight build
/// (distribution profile, production token) — and disagree for the one people
/// actually reach for in between: a RELEASE build installed to a device with a
/// development profile. That build holds a sandbox token and told the Worker
/// "production", so every push went to api.push.apple.com and came back
/// BadDeviceToken — and, since the token really is bad for that host, was
/// dropped as dead. Silent, and exactly the build you reach for when you want
/// to test push without waiting for TestFlight.
///
/// So the profile is asked instead of the compiler.
@MainActor
final class APNsEnvironmentTests: XCTestCase {

    /// A provisioning profile is CMS-wrapped, so the plist sits inside binary
    /// noise. These are the bytes that matter, in the order they appear.
    private func profile(_ value: String) -> String {
        "\u{0}\u{1}garbage<key>application-identifier</key><string>GQZHJ59F4R.com.arc.flighttracker</string>"
        + "<key>aps-environment</key><string>\(value)</string><key>get-task-allow</key><true/>\u{0}"
    }

    func testADevelopmentProfileMeansSandbox() {
        XCTAssertEqual(APNsEnvironment.host(inProfile: profile("development")), "sandbox")
    }

    func testADistributionProfileMeansProduction() {
        XCTAssertEqual(APNsEnvironment.host(inProfile: profile("production")), "production")
    }

    /// THE regression: a Release build carrying a development profile. The
    /// build configuration says one thing and the entitlement says another,
    /// and the entitlement is the one APNs honours.
    func testAReleaseBuildOnADevelopmentProfileStillReportsSandbox() {
        // Same input the archive on this Mac produces — Release-configured,
        // signed "Apple Development", aps-environment: development.
        XCTAssertEqual(APNsEnvironment.host(inProfile: profile("development")), "sandbox")
    }

    /// No profile to read is the Simulator, and there is nothing to correct.
    func testAProfileWithoutTheKeyIsUnknown() {
        XCTAssertNil(APNsEnvironment.host(inProfile: "<key>get-task-allow</key><true/>"))
        XCTAssertNil(APNsEnvironment.host(inProfile: ""))
    }

    /// A truncated or reordered profile must not be read as a guess.
    func testAMalformedValueIsUnknownRatherThanWrong() {
        XCTAssertNil(APNsEnvironment.host(inProfile: "<key>aps-environment</key><string>develop"))
        XCTAssertNil(APNsEnvironment.host(inProfile: "<key>aps-environment</key>"))
    }

    /// An entitlement Apple has not shipped is not silently called production.
    func testAnUnrecognisedValueIsUnknown() {
        XCTAssertNil(APNsEnvironment.host(inProfile: profile("something-new")))
    }
}

/// Who says it: once the device has a registered push token, the Worker
/// announces friend and invite news from the cron the minute it happens,
/// and the local diff must stay quiet — or the same takeoff arrives twice,
/// the second time hours late in a burst the next time the app opens.
final class FriendAlertsOwnershipTests: XCTestCase {
    private let event = FriendAlerts.Event(
        friendName: "Anna", flightId: "f1", flightNumber: "LX2084",
        route: "ZRH → LIS", arrivalCity: "Lisbon", kind: .tookOff)

    func testServerOwnedNewsIsNotPostedLocally() {
        XCTAssertTrue(FriendAlerts.locallyDelivered([event], serverAnnounces: true).isEmpty)
    }

    func testWithoutAPushTokenTheDeviceStillSaysIt() {
        XCTAssertEqual(FriendAlerts.locallyDelivered([event], serverAnnounces: false), [event])
    }

    /// The per-friend "Off" level lives on the device; the server needs the
    /// list to know whose flights this person does not want pushed.
    func testMutedFriendsAreTheOnesSetToOff() {
        let muted = FriendAlerts.mutedFriendIds(levels: [
            "anna": .off, "bea": .notify, "carl": .live, "dan": .off,
        ])
        XCTAssertEqual(muted, ["anna", "dan"])
    }
}
