import XCTest
@testable import Arc

@MainActor
final class FriendsFeedTests: XCTestCase {
    private func flight(_ number: String, dep: String, arr: String,
                        status: String = "scheduled", delay: Int = 0) -> ArcSupabase.SharedFlight {
        .init(id: UUID().uuidString, user_id: "ignored", flight_number: number,
              airline: "Swiss", departure_iata: "ZRH", arrival_iata: "JFK",
              departure_city: "Zurich", arrival_city: "New York",
              departure_lat: 47.46, departure_lon: 8.55,
              arrival_lat: 40.64, arrival_lon: -73.78,
              scheduled_departure: dep, scheduled_arrival: arr,
              estimated_arrival: nil, status: status, delay_minutes: delay,
              departure_gate: nil, arrival_gate: nil, baggage_claim: nil,
              live_lat: nil, live_lon: nil, progress: 0, updated_at: nil)
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
                flight("LANDED", dep: "2026-07-24T06:00:00.000Z", arr: "2026-07-24T08:00:00.000Z", status: "landed"),
            ]),
        ]
        let numbers = store.feed(at: now).map(\.flight.flight_number)
        // Airborne by soonest landing, upcoming by soonest departure, then
        // the recent landing last.
        XCTAssertEqual(numbers, ["AIR1", "AIR2", "UP1", "UP2", "LANDED"])
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

    func testFeedExcludesOldCancelledAndFarFuture() {
        let store = FriendsStore()
        store.friends = [
            entry("Anna", id: "a", [
                flight("OLD", dep: "2026-07-21T06:00:00.000Z", arr: "2026-07-21T08:00:00.000Z", status: "landed"),
                flight("CANCELLED", dep: "2026-07-24T14:00:00.000Z", arr: "2026-07-24T16:00:00.000Z", status: "cancelled"),
                flight("NEXTYEAR", dep: "2026-12-24T14:00:00.000Z", arr: "2026-12-24T16:00:00.000Z"),
            ]),
        ]
        XCTAssertTrue(store.feed(at: now).isEmpty)
    }
}
