import XCTest
@testable import Arc

@MainActor
final class FlightAudienceTests: XCTestCase {
    private func entry(_ name: String, id: String) -> FriendsStore.FriendEntry {
        .init(friendshipId: "f-\(id)",
              user: .init(id: id, display_name: name, handle: nil, avatar_url: nil,
                          home_airport: nil, nationality: nil),
              flights: [])
    }

    private lazy var friends = [entry("Anna", id: "a"), entry("Mike", id: "m"), entry("Vicky", id: "v")]
    private lazy var family = FriendGroup(id: "g1", name: "Family", memberIds: ["a", "v"])

    func testNilIsEveryone() {
        XCTAssertEqual(FlightAudience.summary(ids: nil, friends: friends, groups: [family]), "Everyone")
    }

    func testEmptyIsNoOne() {
        XCTAssertEqual(FlightAudience.summary(ids: [], friends: friends, groups: [family]), "No one")
    }

    /// The common case: a selection that is exactly a group reads as the group,
    /// not as an anonymous count.
    func testExactGroupMatchUsesGroupName() {
        XCTAssertEqual(FlightAudience.summary(ids: ["a", "v"], friends: friends, groups: [family]), "Family")
    }

    func testOneOrTwoPeopleAreNamed() {
        XCTAssertEqual(FlightAudience.summary(ids: ["m"], friends: friends, groups: [family]), "Mike")
        XCTAssertEqual(FlightAudience.summary(ids: ["a", "m"], friends: friends, groups: [family]), "Anna and Mike")
    }

    func testThreeOrMoreFallBackToACount() {
        XCTAssertEqual(FlightAudience.summary(ids: ["a", "m", "v"], friends: friends, groups: [family]),
                       "3 people")
    }

    /// Ids of people who are no longer friends don't count — otherwise a
    /// removed friend keeps padding the summary with someone who can't see it.
    func testUnknownIdsAreIgnored() {
        XCTAssertEqual(FlightAudience.summary(ids: ["m", "ghost"], friends: friends, groups: [family]), "Mike")
        XCTAssertEqual(FlightAudience.summary(ids: ["ghost"], friends: friends, groups: [family]), "No one")
    }
}
