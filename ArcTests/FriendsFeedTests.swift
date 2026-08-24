import XCTest
@testable import Arc

@MainActor
final class FriendsFeedTests: XCTestCase {
    private func flight(_ number: String, dep: String, arr: String,
                        status: String = "scheduled", delay: Int = 0,
                        updatedAt: String? = nil, gate: String? = nil) -> ArcSupabase.SharedFlight {
        .init(id: UUID().uuidString, user_id: "ignored", flight_number: number,
              airline: "Swiss", departure_iata: "ZRH", arrival_iata: "JFK",
              departure_city: "Zurich", arrival_city: "New York",
              departure_lat: 47.46, departure_lon: 8.55,
              arrival_lat: 40.64, arrival_lon: -73.78,
              scheduled_departure: dep, scheduled_arrival: arr,
              estimated_arrival: nil, status: status, delay_minutes: delay,
              departure_gate: gate, arrival_gate: nil, baggage_claim: nil,
              live_lat: nil, live_lon: nil, progress: 0, updated_at: updatedAt)
    }

    private func entry(_ name: String, id: String,
                       _ flights: [ArcSupabase.SharedFlight]) -> FriendsStore.FriendEntry {
        .init(friendshipId: id,
              user: .init(id: id, display_name: name, handle: nil, avatar_url: nil,
                          home_airport: nil, nationality: nil),
              flights: flights)
    }

    private let now = DateHelpers.parseAPIDate("2026-07-24T12:00:00.000Z")!

    func testFeedOrdersAirborneThenUpcomingThenRecentlyLanded() {
        let store = FriendsStore()
        store.friends = [
            entry("Anna", id: "a", [
                flight("AIR2", dep: "2026-07-24T09:00:00.000Z", arr: "2026-07-24T15:00:00.000Z", status: "active"),
                flight("UP2", dep: "2026-07-25T09:00:00.000Z", arr: "2026-07-25T12:00:00.000Z"),
            ]),
            entry("Mike", id: "m", [
                flight("AIR1", dep: "2026-07-24T10:00:00.000Z", arr: "2026-07-24T13:00:00.000Z", status: "active"),
                flight("UP1", dep: "2026-07-24T14:00:00.000Z", arr: "2026-07-24T16:00:00.000Z"),
                // Landed 15 minutes ago — inside the 30-minute grace, so still
                // in the live feed.
                flight("LANDED", dep: "2026-07-24T09:45:00.000Z", arr: "2026-07-24T11:45:00.000Z", status: "landed"),
                // Landed four hours ago — past the grace, so it belongs to the
                // collapsed Past Flights section instead.
                flight("OLD", dep: "2026-07-24T06:00:00.000Z", arr: "2026-07-24T08:00:00.000Z", status: "landed"),
            ]),
        ]
        let numbers = store.feed(at: now).map(\.flight.flight_number)
        // Airborne by soonest landing, upcoming by soonest departure, then
        // the recent landing last.
        XCTAssertEqual(numbers, ["AIR1", "AIR2", "UP1", "UP2", "LANDED"])
    }

    /// The other half of that lifecycle: once the 30-minute grace expires a
    /// flight leaves the live feed and appears under Past Flights. It must do
    /// both — dropping out of one without turning up in the other would make a
    /// friend's completed trip vanish entirely.
    func testLandingLeavesTheFeedForPastFlightsAfterTheGrace() {
        let store = FriendsStore()
        store.friends = [
            entry("Mike", id: "m", [
                flight("OLD", dep: "2026-07-24T06:00:00.000Z", arr: "2026-07-24T08:00:00.000Z", status: "landed"),
            ]),
        ]
        XCTAssertEqual(store.feed(at: now).map(\.flight.flight_number), [])
        XCTAssertEqual(store.pastFeed(at: now).map(\.flight.flight_number), ["OLD"])
    }

    /// A holiday booked months out still shows. The feed used to cut upcoming
    /// off at 30 days, so adding a friend who already had a September trip
    /// showed them with nothing at all — the exact case that made the feature
    /// look broken.
    func testUpcomingHasNoFarHorizon() {
        let store = FriendsStore()
        store.friends = [
            entry("Carl", id: "c", [
                flight("GQ873", dep: "2026-09-06T17:50:00.000Z", arr: "2026-09-06T22:10:00.000Z"),
                flight("SOON", dep: "2026-07-26T09:00:00.000Z", arr: "2026-07-26T12:00:00.000Z"),
            ]),
        ]
        // Both listed, soonest departure first.
        XCTAssertEqual(store.feed(at: now).map(\.flight.flight_number), ["SOON", "GQ873"])
    }

    /// Anna with an ongoing AND an upcoming flight gets ONE map bubble —
    /// for the ongoing one (feed priority) — while the list still shows both.
    func testMapOverlaysShowOneBubblePerFriend() {
        let store = FriendsStore()
        store.friends = [
            entry("Anna", id: "a", [
                flight("UP", dep: "2026-07-25T09:00:00.000Z", arr: "2026-07-25T12:00:00.000Z"),
                flight("AIR", dep: "2026-07-24T09:00:00.000Z", arr: "2026-07-24T15:00:00.000Z", status: "active"),
            ]),
            entry("Mike", id: "m", [
                flight("MUP", dep: "2026-07-24T14:00:00.000Z", arr: "2026-07-24T16:00:00.000Z"),
            ]),
        ]
        // NOTE: overlays use the wall clock; assert on time-independent
        // structure: every flight keeps its arc, but each friend carries at
        // most one bubble.
        let overlays = store.mapOverlays
        let bubbleNames = overlays.filter(\.showsBubble).map(\.name)
        XCTAssertEqual(bubbleNames.count, Set(bubbleNames).count, "one bubble per friend")
        XCTAssertGreaterThanOrEqual(overlays.count, bubbleNames.count, "arcs are not deduped")
        XCTAssertEqual(store.feed(at: now).count, 3, "the feed itself keeps every flight")
    }

    /// Landed-long-ago and cancelled stay out. A far-future flight deliberately
    /// does NOT — see `testUpcomingHasNoFarHorizon`; it used to be dropped here
    /// too, which hid a friend's whole trip the moment you added them.
    func testFeedExcludesOldAndCancelled() {
        let store = FriendsStore()
        store.friends = [
            entry("Anna", id: "a", [
                flight("OLD", dep: "2026-07-21T06:00:00.000Z", arr: "2026-07-21T08:00:00.000Z", status: "landed"),
                flight("CANCELLED", dep: "2026-07-24T14:00:00.000Z", arr: "2026-07-24T16:00:00.000Z", status: "cancelled"),
                flight("NEXTYEAR", dep: "2026-12-24T14:00:00.000Z", arr: "2026-12-24T16:00:00.000Z"),
            ]),
        ]
        XCTAssertEqual(store.feed(at: now).map(\.flight.flight_number), ["NEXTYEAR"])
    }

    // MARK: - transientFlight (the detail screen behind a friend row)

    private func item(_ f: ArcSupabase.SharedFlight) -> FriendsStore.FeedItem {
        .init(user: .init(id: "a", display_name: "Anna", handle: nil, avatar_url: nil,
                          home_airport: nil, nationality: nil), flight: f)
    }

    /// The row was mirrored by the friend's device minutes ago — the detail
    /// screen must say so, not "No live data yet" forever. (transientFlight
    /// never carried `updated_at` across, so the freshness pill hit its
    /// never-updated branch on every friend flight.)
    func testTransientFlightCarriesRowFreshness() {
        let iso = ISO8601DateFormatter()
        let f = flight("LX1950", dep: iso.string(from: .now.addingTimeInterval(3600)),
                       arr: iso.string(from: .now.addingTimeInterval(3 * 3600)),
                       updatedAt: iso.string(from: .now.addingTimeInterval(-3 * 60)))
        let transient = FriendsStore().transientFlight(for: item(f))
        XCTAssertNotNil(transient.lastStatusUpdate)
        XCTAssertTrue(transient.isDataFresh)
        XCTAssertNotEqual(transient.dataFreshnessShort, "—")
    }

    /// A friend whose aircraft has pushed back but not yet left the ground
    /// must stay on the feed and on the map. The old code kept them visible
    /// by calling them airborne at the gate time; the honest phases must not
    /// lose them instead — the taxi is exactly when people watch.
    func testFeedAndMapKeepAFlightThatHasLeftTheGateButNotTheGround() {
        let iso = ISO8601DateFormatter()
        let f = flight("LX638", dep: iso.string(from: .now.addingTimeInterval(-8 * 60)),
                       arr: iso.string(from: .now.addingTimeInterval(80 * 60)),
                       status: "gateClosed")
        XCTAssertEqual(FriendFlightMath.departurePhase(f), .departing)
        XCTAssertFalse(FriendFlightMath.isAirborne(f))

        let store = FriendsStore()
        store.friends = [entry("Anna", id: "anna", [f])]
        XCTAssertEqual(store.feed(at: .now).count, 1, "the taxiing friend vanished from the feed")
        XCTAssertNotNil(FriendFlightMath.spotlight(from: [f]), "and from the map")
        XCTAssertTrue(store.pastFeed(at: .now).isEmpty, "and must not be filed as past")
    }

    /// Fifteen minutes past the gate time with the row still saying
    /// "scheduled": the friend's screens must not call that flying. The chip
    /// says DEPARTING, the sheet says it has not departed, and neither
    /// invents a take-off — the clock heal that used to run here is exactly
    /// what announced "IN FLIGHT" to someone watching a taxiing aircraft.
    func testTransientFlightDoesNotInventATakeoffFromTheClock() {
        let iso = ISO8601DateFormatter()
        let f = flight("LX1950", dep: iso.string(from: .now.addingTimeInterval(-15 * 60)),
                       arr: iso.string(from: .now.addingTimeInterval(105 * 60)))
        XCTAssertEqual(FriendFlightMath.departurePhase(f), .departing)
        XCTAssertFalse(FriendFlightMath.isAirborne(f))
        let transient = FriendsStore().transientFlight(for: item(f))
        XCTAssertFalse(transient.isActive)
        XCTAssertNil(transient.actualDeparture)
        XCTAssertEqual(transient.statusText, "Not yet departed")
        XCTAssertTrue(transient.departureRelText.hasSuffix("past schedule"))
    }

    /// The server (or the traveller's own phone, before it went dark) saw the
    /// aircraft rolling. That crosses to the friend, chip and sheet alike.
    func testTransientFlightCarriesTaxiingFromTheSharedRow() {
        let iso = ISO8601DateFormatter()
        var f = flight("LX1950", dep: iso.string(from: .now.addingTimeInterval(-14 * 60)),
                       arr: iso.string(from: .now.addingTimeInterval(105 * 60)))
        f.ground_state = "taxiing"
        f.taxi_started_at = iso.string(from: .now.addingTimeInterval(-12 * 60))
        f.ground_observed_at = iso.string(from: .now.addingTimeInterval(-60))
        XCTAssertEqual(FriendFlightMath.departurePhase(f),
                       .taxiing(since: DateHelpers.parseAPIDate(f.taxi_started_at)))
        XCTAssertFalse(FriendFlightMath.isAirborne(f), "taxiing is not flying")
        XCTAssertEqual(Int((FriendFlightMath.taxiElapsed(f) ?? 0) / 60), 12)
        XCTAssertEqual(FriendsStore().transientFlight(for: item(f)).statusText, "Taxiing")
    }

    /// Past the expected wheels-up with nothing confirmed, the feed does
    /// treat the leg as under way — a friend still wants the arrival
    /// countdown — but it got there by evidence, not by the gate clock.
    func testTransientFlightPresumesAirborneOnlyAfterTheTaxiWindow() {
        let iso = ISO8601DateFormatter()
        let f = flight("LX1950", dep: iso.string(from: .now.addingTimeInterval(-45 * 60)),
                       arr: iso.string(from: .now.addingTimeInterval(75 * 60)))
        XCTAssertEqual(FriendFlightMath.departurePhase(f), .presumedAirborne)
        XCTAssertTrue(FriendFlightMath.isAirborne(f))
        XCTAssertTrue(FriendsStore().transientFlight(for: item(f)).isActive)
    }

    /// A reported take-off crosses to the reader: the shared row's
    /// `actual_departure` becomes the transient flight's, ending the hedge.
    func testTransientFlightCarriesConfirmedDeparture() {
        let iso = ISO8601DateFormatter()
        let dep = Date.now.addingTimeInterval(-15 * 60)
        var f = flight("LX1950", dep: iso.string(from: dep),
                       arr: iso.string(from: .now.addingTimeInterval(105 * 60)), status: "active")
        f.actual_departure = iso.string(from: dep.addingTimeInterval(4 * 60))
        let transient = FriendsStore().transientFlight(for: item(f))
        XCTAssertNotNil(transient.actualDeparture)
        XCTAssertFalse(transient.isDepartingUnconfirmed)
        XCTAssertTrue(transient.departureRelText.hasSuffix(" ago"))
    }

    // MARK: - shouldAskServer (the gate on the on-demand refresh)

    /// A leg the provider cannot answer for is never worth a call.
    private func mode(_ f: ArcSupabase.SharedFlight, _ m: String) -> ArcSupabase.SharedFlight {
        var copy = f
        copy.mode = m
        return copy
    }

    /// THE regression. The cron ignores anything more than thirty hours from
    /// departure, and that bound is right for the cron: it is about the cost of
    /// consulting every shared row, every hour, for ever. It was also being
    /// applied to an explicit open — one call, made because a person asked for
    /// it, already deduplicated server-side to once a minute and riding a
    /// cached negative answer besides.
    ///
    /// So a friend's flight three weeks out made no network call at all, and
    /// its detail screen counted upward from whenever the traveller's phone had
    /// last happened to write the row — "Updated 16h ago", then a day, then a
    /// week — with nothing in the system that would ever reset it.
    func testAnOpenAsksEvenWhenTheCronWouldNotBother() {
        let f = flight("FAR", dep: "2026-08-17T09:00:00.000Z", arr: "2026-08-17T12:00:00.000Z")
        XCTAssertTrue(FriendsStore().shouldAskServer(item(f), at: now))
    }

    /// The horizon is not merely wider than the cron's — it is absent. Any
    /// number here would just relocate the bug to a flight booked further out.
    func testNoDepartureIsTooFarOutToAskAbout() {
        let f = flight("NEXTYEAR", dep: "2027-07-24T09:00:00.000Z", arr: "2027-07-24T12:00:00.000Z")
        XCTAssertTrue(FriendsStore().shouldAskServer(item(f), at: now))
    }

    func testAFlightInTheAirIsWorthAsking() {
        let f = flight("AIR", dep: "2026-07-24T10:00:00.000Z", arr: "2026-07-24T15:00:00.000Z",
                       status: "active")
        XCTAssertTrue(FriendsStore().shouldAskServer(item(f), at: now))
    }

    /// Past the landing grace there is nothing left to learn, so the one guard
    /// that genuinely bounds this must survive.
    func testAFlightLandedLongAgoIsFinished() {
        let f = flight("OLD", dep: "2026-07-24T04:00:00.000Z", arr: "2026-07-24T08:00:00.000Z",
                       status: "landed")
        XCTAssertFalse(FriendsStore().shouldAskServer(item(f), at: now))
    }

    func testAFlightThatJustLandedIsStillInsideTheGrace() {
        let f = flight("JUST", dep: "2026-07-24T09:45:00.000Z", arr: "2026-07-24T11:45:00.000Z",
                       status: "landed")
        XCTAssertTrue(FriendsStore().shouldAskServer(item(f), at: now))
    }

    func testACancelledFlightIsNotAskedAbout() {
        let f = flight("CXL", dep: "2026-07-24T14:00:00.000Z", arr: "2026-07-24T16:00:00.000Z",
                       status: "cancelled")
        XCTAssertFalse(FriendsStore().shouldAskServer(item(f), at: now))
    }

    /// AeroDataBox cannot answer for rail or sea, so asking burns a
    /// budget-guarded call on a guaranteed miss. This is the deliberate
    /// device-only caveat, and widening the horizon must not quietly undo it.
    func testRailAndFerryLegsAreStillDeviceOnly() {
        let f = flight("TRAIN", dep: "2026-07-24T14:00:00.000Z", arr: "2026-07-24T16:00:00.000Z")
        XCTAssertFalse(FriendsStore().shouldAskServer(item(mode(f, "rail")), at: now))
        XCTAssertFalse(FriendsStore().shouldAskServer(item(mode(f, "sea")), at: now))
        XCTAssertTrue(FriendsStore().shouldAskServer(item(mode(f, "air")), at: now))
    }

    // MARK: - apply (refreshing the detail sheet that is already open)

    /// The sheet is presented with `.sheet(item:)`, keyed on `Flight.id` — a
    /// fresh UUID per construction. Replacing the object would therefore
    /// dismiss and re-present the sheet in the reader's face, so a refreshed
    /// row has to be written onto the instance already on screen.
    func testApplyingAFreshRowKeepsTheOnscreenIdentity() {
        let store = FriendsStore()
        let stale = flight("GQ21", dep: "2026-08-17T09:00:00.000Z", arr: "2026-08-17T12:00:00.000Z",
                           updatedAt: "2026-07-23T20:00:00.000Z")
        let onscreen = store.transientFlight(for: item(stale))
        let identity = onscreen.id
        let before = onscreen.lastStatusUpdate

        var fresh = stale
        fresh.checked_at = "2026-07-24T11:59:30.000Z"
        store.apply(item(fresh), to: onscreen)

        XCTAssertEqual(onscreen.id, identity,
                       "a new object would re-present the sheet instead of updating it")
        XCTAssertNotEqual(onscreen.lastStatusUpdate, before)
        XCTAssertEqual(onscreen.lastStatusUpdate, DateHelpers.parseAPIDate(fresh.checked_at))
    }

    /// `refreshLive` used to update the store and stop there, so the sheet went
    /// on showing the snapshot it opened with — the screen the comment above
    /// `feedRow` already claimed would "update underneath when the answer comes
    /// back". A gate that arrives while the reader is looking at the sheet is
    /// exactly the news they opened it for.
    func testApplyingAFreshRowShowsWhatChanged() {
        let store = FriendsStore()
        let stale = flight("GQ21", dep: "2026-08-17T09:00:00.000Z", arr: "2026-08-17T12:00:00.000Z")
        let onscreen = store.transientFlight(for: item(stale))
        XCTAssertNil(onscreen.departureGate)

        let fresh = flight("GQ21", dep: "2026-08-17T09:00:00.000Z", arr: "2026-08-17T12:00:00.000Z",
                           delay: 25, gate: "A12")
        store.apply(item(fresh), to: onscreen)

        XCTAssertEqual(onscreen.departureGate, "A12")
        XCTAssertEqual(onscreen.delayMinutes, 25)
    }
}
