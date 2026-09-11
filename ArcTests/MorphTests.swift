import XCTest
@testable import Arc

/// The list is present at the start of the travel and the detail at the
/// end, and neither is half-there for long: the departing side is gone by
/// the time the arriving one begins to show.
final class MorphTests: XCTestCase {
    func testTheTwoSidesNeverOverlapMidTravel() {
        for p in stride(from: 0.0, through: 1.0, by: 0.05) {
            let list = Morph.presence(1 - p), detail = Morph.presence(p)
            XCTAssertLessThanOrEqual(min(list, detail), 0.0001, "both visible at \(p)")
        }
        XCTAssertEqual(Morph.presence(0), 0)
        XCTAssertEqual(Morph.presence(1), 1)
    }
}
