import XCTest
@testable import Arc

/// Opening and closing must never expose an empty sheet between surfaces.
final class MorphTests: XCTestCase {
    func testTransitionNeverBlanksBothSurfaces() {
        for p in stride(from: 0.0, through: 1.0, by: 0.01) {
            let list = Morph.presence(1 - p), detail = Morph.presence(p)
            XCTAssertEqual(list + detail, 1, accuracy: 0.0001, "coverage lost at \(p)")
            XCTAssertGreaterThanOrEqual(max(list, detail), 0.5)
        }
        XCTAssertEqual(Morph.presence(0), 0)
        XCTAssertEqual(Morph.presence(1), 1)
    }

    func testSpringOvershootKeepsOpacityInBounds() {
        XCTAssertEqual(Morph.presence(-0.1), 0)
        XCTAssertEqual(Morph.presence(1.1), 1)
    }
}
