import XCTest
@testable import Arc

/// The detail's elements rise in turn and leave in the reverse turn, so
/// close is open played backwards: the header, first in, is last out.
final class MorphTests: XCTestCase {
    func testTurnsRunForwardOnShowAndBackwardOnHide() {
        XCTAssertEqual(RiseIn(shown: true, index: 0, count: 5).turn, 0)
        XCTAssertEqual(RiseIn(shown: true, index: 4, count: 5).turn, 4)
        XCTAssertEqual(RiseIn(shown: false, index: 0, count: 5).turn, 4)
        XCTAssertEqual(RiseIn(shown: false, index: 4, count: 5).turn, 0)
    }
}
