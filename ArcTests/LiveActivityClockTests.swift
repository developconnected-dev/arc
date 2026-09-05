import XCTest
@testable import Arc

/// The clock every Live Activity surface reads — lock, compact Island,
/// expanded Island. VY8462 showed three different times at 20:33 because
/// local `makeState` and the Worker push each built their own.
@MainActor
final class LiveActivityClockTests: XCTestCase {
    /// 19:45 BCN (UTC+2) = 17:45Z. 21:35 LIS (UTC+1) = 20:35Z.
    private let scheduledDep = Date(timeIntervalSince1970: 1_788_371_100)
    private let scheduledArr = Date(timeIntervalSince1970: 1_788_381_300)
    private let estimatedArr = Date(timeIntervalSince1970: 1_788_379_200) // 21:00 LIS
    private let wheelsUp = Date(timeIntervalSince1970: 1_788_370_860)     // 19:41 BCN

    private func clock(delay: Int = 5, actualDeparture: Date? = nil,
                       estimatedArrival: Date? = nil) -> FlightActivityAttributes.ContentState.Clock {
        FlightActivityAttributes.ContentState.clock(
            scheduledDeparture: scheduledDep,
            scheduledArrival: scheduledArr,
            delayMinutes: delay,
            actualDeparture: actualDeparture,
            estimatedArrival: estimatedArrival)
    }

    /// Lock-screen snapshot from the bug: 19:50 (5m Late) → 21:00 (35m Early).
    func testEstimatedArrivalIsIndependentOfDepartureDelay() {
        let c = clock(estimatedArrival: estimatedArr)
        XCTAssertEqual(c.departureTime, scheduledDep.addingTimeInterval(5 * 60))
        XCTAssertEqual(c.arrivalTime, estimatedArr)
        XCTAssertEqual(c.delayMinutes, 5)
        XCTAssertEqual(c.arrivalDelayMinutes, -35)
    }

    /// Mira: stale-but-matching. Wheels-up next to "5m Late" is a card that
    /// disagrees with itself — lock 19:50 / Island 19:41 on VY8462.
    func testDisplayedDepartureIsTheGateTimeTheAirlineTagDescribes() {
        let c = clock(actualDeparture: wheelsUp, estimatedArrival: estimatedArr)
        XCTAssertEqual(c.departureTime, scheduledDep.addingTimeInterval(5 * 60))
        XCTAssertEqual(c.arrivalTime, estimatedArr)
        XCTAssertEqual(c.delayMinutes, 5)
        XCTAssertEqual(c.arrivalDelayMinutes, -35)
    }

    /// Arc ✦ arrival tag, airline dep tag, until-gate, and progress share
    /// one snapshot. Inventing the arrival tag from the departure delay is
    /// how 21:00 sat next to "5m Late".
    func testArrivalTagDoesNotFallBackToDepartureDelay() {
        let state = FlightActivityAttributes.ContentState(
            status: "active",
            departureTime: scheduledDep.addingTimeInterval(5 * 60),
            arrivalTime: estimatedArr,
            boardingTime: nil,
            delayMinutes: 5,
            arrivalDelayMinutes: nil,
            departureGate: nil, departureTerminal: nil,
            arrivalGate: nil, arrivalTerminal: nil,
            baggageClaim: nil, progress: 0.6)
        XCTAssertEqual(state.departureDelayMinutes, 5)
        XCTAssertNil(state.matchedArrivalDelayMinutes)
        XCTAssertEqual(state.gateArrival, estimatedArr)
        XCTAssertEqual(state.progressInterval.lowerBound, state.departureTime)
        XCTAssertEqual(state.progressInterval.upperBound, state.arrivalTime)
    }

    func testMatchingSnapshotKeepsArrivalTagWithTheETA() {
        let state = FlightActivityAttributes.ContentState(
            status: "active",
            departureTime: scheduledDep.addingTimeInterval(5 * 60),
            arrivalTime: estimatedArr,
            boardingTime: nil,
            delayMinutes: 5,
            arrivalDelayMinutes: -35,
            departureGate: nil, departureTerminal: nil,
            arrivalGate: nil, arrivalTerminal: nil,
            baggageClaim: nil, progress: 0.6)
        XCTAssertEqual(state.matchedArrivalDelayMinutes, -35)
        XCTAssertEqual(state.gateArrival, estimatedArr)
    }

    /// An estimate that is not after departure is yesterday's leftover, not this ETA.
    func testImplausibleEstimateFallsBackToSchedulePlusDelay() {
        let c = clock(estimatedArrival: scheduledDep.addingTimeInterval(-60))
        XCTAssertEqual(c.arrivalTime, scheduledArr.addingTimeInterval(5 * 60))
        XCTAssertEqual(c.arrivalDelayMinutes, 5)
    }

    func testNoDelayAndNoEstimateIsTheSchedule() {
        let c = clock(delay: 0)
        XCTAssertEqual(c.departureTime, scheduledDep)
        XCTAssertEqual(c.arrivalTime, scheduledArr)
        XCTAssertEqual(c.arrivalDelayMinutes, 0)
    }
}

@MainActor
final class LiveActivitySamePlaneTests: XCTestCase {
    private func attrs(number: String, dep: String, arr: String,
                       friend: String? = nil) -> FlightActivityAttributes {
        FlightActivityAttributes(
            flightNumber: number, departureIATA: dep, arrivalIATA: arr,
            departureCity: "", arrivalCity: "", airline: "",
            aircraftType: nil, seat: nil, friendName: friend)
    }

    /// Own + friend cards for VY8462 BCN→LIS are one plane. The Island
    /// picks one activity; the lock screen can show the other.
    func testOwnAndFriendOnTheSameRouteAreTheSamePlane() {
        let own = attrs(number: "VY8462", dep: "BCN", arr: "LIS")
        let friend = attrs(number: "VY 8462", dep: "BCN", arr: "LIS", friend: "Victoria")
        XCTAssertTrue(LiveActivityManager.isSamePlane(own, friend))
    }

    func testADifferentRouteIsNotTheSamePlane() {
        let a = attrs(number: "VY8462", dep: "BCN", arr: "LIS")
        let b = attrs(number: "VY8462", dep: "BCN", arr: "MAD")
        XCTAssertFalse(LiveActivityManager.isSamePlane(a, b))
    }

    func testOwnIsPreferredOverFriendOnTheSamePlane() {
        XCTAssertTrue(LiveActivityManager.preferOwnOverFriend(
            existing: attrs(number: "VY8462", dep: "BCN", arr: "LIS", friend: "Victoria"),
            incomingIsOwn: true))
        XCTAssertFalse(LiveActivityManager.preferOwnOverFriend(
            existing: attrs(number: "VY8462", dep: "BCN", arr: "LIS"),
            incomingIsOwn: false))
    }
}
