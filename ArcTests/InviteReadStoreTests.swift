import XCTest
@testable import Arc

@MainActor
final class InviteReadStoreTests: XCTestCase {
    private static let suite = "InviteReadStoreTests"

    private func store() -> InviteReadStore {
        let defaults = UserDefaults(suiteName: Self.suite)!
        defaults.removePersistentDomain(forName: Self.suite)
        return InviteReadStore(defaults: defaults)
    }

    func testAnInviteIsUnreadUntilItHasBeenSeen() {
        let s = store()
        XCTAssertTrue(s.hasUnread(among: ["a", "b"]))
        s.markSeen("a")
        XCTAssertTrue(s.hasUnread(among: ["a", "b"]))
        s.markSeen("b")
        XCTAssertFalse(s.hasUnread(among: ["a", "b"]))
    }

    func testSeenStatePersists() {
        let defaults = UserDefaults(suiteName: Self.suite)!
        defaults.removePersistentDomain(forName: Self.suite)
        InviteReadStore(defaults: defaults).markSeen("a")
        XCTAssertFalse(InviteReadStore(defaults: defaults).hasUnread(among: ["a"]))
    }

    /// Ids of invites that are gone must not pile up forever.
    func testForgottenInvitesAreDropped() {
        let s = store()
        s.markSeen("a"); s.markSeen("b")
        s.prune(keeping: ["b"])
        XCTAssertEqual(s.seen, ["b"])
        XCTAssertTrue(s.hasUnread(among: ["a"]))
    }

    /// Trip invites and friend requests keep their read state apart: a
    /// request seen must not quiet an invite's dot, or the other way round.
    func testStoresWithDifferentKeysDoNotShareState() {
        let defaults = UserDefaults(suiteName: Self.suite)!
        defaults.removePersistentDomain(forName: Self.suite)
        let invites = InviteReadStore(defaults: defaults, key: "invites.seen")
        let requests = InviteReadStore(defaults: defaults, key: "friendRequests.seen")
        invites.markSeen("a")
        requests.markSeen("b")
        XCTAssertTrue(requests.hasUnread(among: ["a"]))
        XCTAssertTrue(invites.hasUnread(among: ["b"]))
        requests.prune(keeping: [])
        XCTAssertFalse(InviteReadStore(defaults: defaults, key: "invites.seen").hasUnread(among: ["a"]))
        XCTAssertTrue(InviteReadStore(defaults: defaults, key: "friendRequests.seen").hasUnread(among: ["b"]))
    }
}
