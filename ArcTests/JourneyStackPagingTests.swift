import XCTest
@testable import Arc

final class JourneyStackPagingTests: XCTestCase {
    typealias P = JourneyStackPaging
    let gap = JourneyStackPaging.gap

    func testTravelIsTheLandingCardPlusGap() {
        XCTAssertEqual(P.travel(direction: .next, current: 120, neighbour: 260), 260 + gap)
        XCTAssertEqual(P.travel(direction: .previous, current: 120, neighbour: 260), 120 + gap)
    }

    func testProgressAndLiveHeight() {
        XCTAssertEqual(P.progress(drag: -135, travel: 270), 0.5, accuracy: 1e-9)
        XCTAssertEqual(P.progress(drag: 999, travel: 270), 1)
        XCTAssertEqual(P.liveHeight(current: 120, neighbour: 260, progress: 0.5), 190, accuracy: 1e-9)
    }

    /// At rest the current card sits at the frame's top; at the end of a flip
    /// the landing card does, so committing the page is pixel-identical.
    func testOffsetsLandEachCardAtTheFrameTop() {
        let h0: CGFloat = 120, hN: CGFloat = 260, hP: CGFloat = 90
        let rest = P.offsets(drag: 0, current: h0, next: hN, previous: hP)
        XCTAssertEqual(rest.current, 0, accuracy: 1e-9)
        XCTAssertEqual(rest.next, h0 + gap, accuracy: 1e-9)
        XCTAssertEqual(rest.previous, -(hP + gap), accuracy: 1e-9)

        let up = P.offsets(drag: -(hN + gap), current: h0, next: hN, previous: hP)
        XCTAssertEqual(up.next, 0, accuracy: 1e-9)
        XCTAssertEqual(up.frameHeight, hN, accuracy: 1e-9)

        let down = P.offsets(drag: h0 + gap, current: h0, next: hN, previous: hP)
        XCTAssertEqual(down.previous, 0, accuracy: 1e-9)
        XCTAssertEqual(down.frameHeight, hP, accuracy: 1e-9)
    }

    /// Leaving upward, the current card never hangs below the frame it is leaving.
    func testCurrentCardNeverHangsBelowTheFrameWhileLeaving() {
        for f in stride(from: 0.0, through: 1.0, by: 0.05) {
            let drag = -f * (260 + gap)
            let o = P.offsets(drag: drag, current: 120, next: 260, previous: 90)
            // Current card bottom (relative to frame top) never below the frame bottom before it leaves.
            XCTAssertLessThanOrEqual(o.current + 120, o.frameHeight + 1e-6)
        }
    }

    func testReleaseTarget() {
        // Short slow drag: stays.
        XCTAssertEqual(P.target(page: 1, count: 4, drag: -40, predictedEnd: -60, travel: 270), 1)
        // Past a third: commits.
        XCTAssertEqual(P.target(page: 1, count: 4, drag: -100, predictedEnd: -110, travel: 270), 2)
        // Short but flicked: commits.
        XCTAssertEqual(P.target(page: 1, count: 4, drag: -30, predictedEnd: -200, travel: 270), 2)
        XCTAssertEqual(P.target(page: 1, count: 4, drag: 30, predictedEnd: 200, travel: 270), 0)
        // Never more than one page, never past the ends.
        XCTAssertEqual(P.target(page: 3, count: 4, drag: -400, predictedEnd: -900, travel: 270), 3)
        XCTAssertEqual(P.target(page: 0, count: 4, drag: 400, predictedEnd: 900, travel: 270), 0)
        XCTAssertEqual(P.target(page: 0, count: 1, drag: -400, predictedEnd: -900, travel: 270), 0)
    }

    /// A drag built up past the commit share toward `next`, but the velocity at
    /// release has reversed toward `previous`: the neighbour in that direction
    /// was never in view during the drag, so the flip cancels rather than
    /// landing on it.
    func testAFlickBackBeforeReleaseCancels() {
        XCTAssertEqual(P.target(page: 1, count: 4, drag: -180, predictedEnd: 20, travel: 270), 1)
        // Symmetric case, reversed toward next instead.
        XCTAssertEqual(P.target(page: 1, count: 4, drag: 180, predictedEnd: -20, travel: 270), 1)
        // A strong reverse flick still just cancels: there is no third page to land on.
        XCTAssertEqual(P.target(page: 1, count: 4, drag: -180, predictedEnd: 400, travel: 270), 1)
    }

    func testRubberBandDampsAndKeepsSign() {
        let d = P.rubberBanded(-300, dimension: 150)
        XCTAssertLessThan(d, 0)
        XCTAssertGreaterThan(d, -150)
        XCTAssertEqual(P.rubberBanded(0, dimension: 150), 0)
        XCTAssertLessThan(abs(P.rubberBanded(-10, dimension: 150)), 10)
    }

    func testPageFollowsItsJourneyWhenTheListChanges() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        // Current journey still there, moved: follow it.
        XCTAssertEqual(P.page(after: [a, b, c], now: [d, a, b, c], was: 1), 2)
        // Current journey gone: same index, clamped.
        XCTAssertEqual(P.page(after: [a, b, c], now: [a, c], was: 1), 1)
        XCTAssertEqual(P.page(after: [a, b, c], now: [a], was: 2), 0)
        XCTAssertEqual(P.page(after: [a], now: [], was: 0), 0)
    }
}
