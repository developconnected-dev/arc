import XCTest
@testable import Arc

final class TripTransitionTests: XCTestCase {
    func testRepeatedOpenCloseOpenAlwaysGetsANewRequest() throws {
        var state = TripTransition()
        for _ in 0..<20 {
            state.open()
            let opening = try XCTUnwrap(state.request)
            XCTAssertEqual(opening.target, 1)
            XCTAssertTrue(state.finish(opening.id))
            XCTAssertEqual(state.phase, .detail)
            state.close()
            let closing = try XCTUnwrap(state.request)
            XCTAssertNotEqual(opening.id, closing.id)
            XCTAssertFalse(state.finish(opening.id))
            XCTAssertTrue(state.finish(closing.id))
            XCTAssertEqual(state.phase, .list)
            XCTAssertNil(state.request)
        }
    }

    func testCloseDuringOpeningIgnoresOldCompletion() throws {
        var state = TripTransition()
        state.open()
        let first = try XCTUnwrap(state.request)
        state.close()
        let close = try XCTUnwrap(state.request)
        XCTAssertFalse(state.finish(first.id))
        XCTAssertEqual(state.phase, .closing)
        XCTAssertTrue(state.finish(close.id))
        XCTAssertEqual(state.phase, .list)
    }

    func testAnotherFlightDuringCloseCannotBeDismissedByOldCompletion() throws {
        var state = TripTransition()
        state.close()
        let old = try XCTUnwrap(state.request)
        state.open()
        let next = try XCTUnwrap(state.request)
        XCTAssertFalse(state.finish(old.id))
        XCTAssertEqual(state.request, next)
        XCTAssertTrue(state.finish(next.id))
        XCTAssertEqual(state.phase, .detail)
    }

    func testFallbackAndAnimationCompletionCannotFinishTwice() throws {
        var state = TripTransition()
        state.open()
        let request = try XCTUnwrap(state.request)
        XCTAssertTrue(state.finish(request.id))
        XCTAssertFalse(state.finish(request.id))
        XCTAssertNil(state.request)
    }

    func testReducedMotionInvalidatesPendingCompletion() throws {
        var state = TripTransition()
        state.open()
        let request = try XCTUnwrap(state.request)
        state.settle(detail: false)
        XCTAssertFalse(state.finish(request.id))
        XCTAssertEqual(state.phase, .list)
    }
}
