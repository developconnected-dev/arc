import XCTest
@testable import Arc

@MainActor
final class FriendGroupsTests: XCTestCase {
    // Tests share the host app's UserDefaults, so anything left behind shows
    // up as a real group next time the app runs on this simulator.
    override func setUp() {
        super.setUp()
        FriendGroups.save([])
    }

    override func tearDown() {
        FriendGroups.save([])
        super.tearDown()
    }

    func testUpsertAddsThenUpdatesInPlace() {
        var family = FriendGroup(name: "Family", memberIds: ["anna"])
        FriendGroups.upsert(family)
        XCTAssertEqual(FriendGroups.all().count, 1)

        family.name = "Close Family"
        family.memberIds.insert("mike")
        FriendGroups.upsert(family)

        // Same id → replaced, not appended.
        XCTAssertEqual(FriendGroups.all().count, 1)
        XCTAssertEqual(FriendGroups.all().first?.name, "Close Family")
        XCTAssertEqual(FriendGroups.all().first?.memberIds, ["anna", "mike"])
    }

    func testDeleteRemovesOnlyThatGroup() {
        let family = FriendGroup(name: "Family")
        let work = FriendGroup(name: "Work")
        FriendGroups.upsert(family)
        FriendGroups.upsert(work)

        FriendGroups.delete(family.id)
        XCTAssertEqual(FriendGroups.all().map(\.name), ["Work"])
    }

    /// Removing a friendship has to drop that person from every group, or a
    /// group keeps claiming a member who is no longer a friend — and the feed
    /// filter then quietly shows fewer people than the chip implies.
    func testPruningDropsMemberFromEveryGroup() {
        let groups = [
            FriendGroup(name: "Family", memberIds: ["anna", "mike"]),
            FriendGroup(name: "Close", memberIds: ["anna"]),
            FriendGroup(name: "Work", memberIds: ["mike"]),
        ]
        let pruned = FriendGroups.pruning("anna", from: groups)

        XCTAssertEqual(pruned.map(\.memberIds), [["mike"], [], ["mike"]])
        // Names and ids survive — only membership changes.
        XCTAssertEqual(pruned.map(\.name), groups.map(\.name))
        XCTAssertEqual(pruned.map(\.id), groups.map(\.id))
    }

    func testGroupsRoundTripThroughStorage() {
        let group = FriendGroup(name: "Family", memberIds: ["a", "b"])
        FriendGroups.upsert(group)
        XCTAssertEqual(FriendGroups.all(), [group])
    }
}
