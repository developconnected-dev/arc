import XCTest
@testable import Arc

/// Opening a detail raises the sheet to large and remembers where it was;
/// closing puts it back. A second open on top of the first keeps the
/// ORIGINAL height, so closing after a crossfade returns to where the user
/// started, not to "large".
final class DetailPresentationTests: XCTestCase {
    func testOpenRaisesToLargeAndRemembersTheStart() {
        var p = DetailPresentation()
        XCTAssertEqual(p.open(from: .medium), .large)
        XCTAssertEqual(p.close(), .medium)
    }

    func testCloseWithoutOpenRestoresNothing() {
        var p = DetailPresentation()
        XCTAssertNil(p.close())
    }

    func testReplacingAnOpenDetailKeepsTheFirstRememberedHeight() {
        var p = DetailPresentation()
        _ = p.open(from: .small)
        _ = p.open(from: .large)
        XCTAssertEqual(p.close(), .small)
    }

    func testOpeningFromLargeRestoresLarge() {
        var p = DetailPresentation()
        XCTAssertEqual(p.open(from: .large), .large)
        XCTAssertEqual(p.close(), .large)
    }
}
