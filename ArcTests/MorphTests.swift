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

    /// The travelling copy carries its own glass only mid-flight: at either
    /// end the card or the panel already draws glass beneath it.
    func testTravelGlassIsAbsentAtBothEndsAndWholeMidway() {
        XCTAssertEqual(Morph.travelGlass(0), 0)
        XCTAssertEqual(Morph.travelGlass(1), 0)
        XCTAssertEqual(Morph.travelGlass(0.5), 1)
        for p in stride(from: -0.1, through: 1.1, by: 0.01) {
            XCTAssertTrue((0...1).contains(Morph.travelGlass(p)), "p=\(p)")
        }
    }

    /// The header is measured while the panel is still risen by the rest of
    /// its rise; the glide must aim where the header will settle.
    func testSettledFrameRemovesTheRemainingRise() {
        let r = CGRect(x: 10, y: 400, width: 300, height: 120)
        XCTAssertEqual(Morph.settledFrame(r, progress: 0).minY, 400 - Morph.panelRise)
        XCTAssertEqual(Morph.settledFrame(r, progress: 0.5).minY, 400 - Morph.panelRise / 2)
        XCTAssertEqual(Morph.settledFrame(r, progress: 1), r)
    }
}
