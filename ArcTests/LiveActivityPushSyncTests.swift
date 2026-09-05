import XCTest
@testable import Arc

/// The identity fallback that lets a push reach the store when the card's
/// attributes carry no flightId — every card the server started did, until
/// the Worker learned to send one, and attributes are minted for life.
@MainActor
final class LiveActivityPushSyncTests: XCTestCase {
    private func flight(_ number: String, dep: String, arr: String, departure: Date) -> Flight {
        let f = Flight(flightNumber: number, date: departure)
        f.scheduledDeparture = departure
        f.scheduledArrival = departure.addingTimeInterval(2 * 3600)
        f.departureIATA = dep
        f.arrivalIATA = arr
        return f
    }

    func testMatchesByIdentityAndClosestDeparture() {
        let dep = Date(timeIntervalSince1970: 1_800_000_000)
        let yesterday = flight("LX2146", dep: "ZRH", arr: "VLC", departure: dep.addingTimeInterval(-24 * 3600))
        let today = flight("LX 2146", dep: "ZRH", arr: "VLC", departure: dep)
        let otherRoute = flight("LX2146", dep: "ZRH", arr: "BCN", departure: dep)
        // `around` is the card's EFFECTIVE departure — a delayed flight must
        // still find itself, not its daily sibling.
        let match = LiveActivityPushSync.matchFlight(
            [yesterday, otherRoute, today],
            number: "LX2146", dep: "ZRH", arr: "VLC",
            around: dep.addingTimeInterval(25 * 60))
        XCTAssertTrue(match === today)
    }

    /// Half a day of drift means another day's operation, not a delayed one —
    /// better no absorb than stamping yesterday's card onto today's flight.
    func testNoMatchBeyondHalfADay() {
        let dep = Date(timeIntervalSince1970: 1_800_000_000)
        let wrongDay = flight("LX2146", dep: "ZRH", arr: "VLC", departure: dep.addingTimeInterval(-24 * 3600))
        XCTAssertNil(LiveActivityPushSync.matchFlight(
            [wrongDay], number: "LX2146", dep: "ZRH", arr: "VLC", around: dep))
    }

    func testNoMatchForDifferentRoute() {
        let dep = Date(timeIntervalSince1970: 1_800_000_000)
        let otherRoute = flight("LX2146", dep: "ZRH", arr: "BCN", departure: dep)
        XCTAssertNil(LiveActivityPushSync.matchFlight(
            [otherRoute], number: "LX2146", dep: "ZRH", arr: "VLC", around: dep))
    }

    /// Schedule+delay is the timetable fallback, not an airline revision.
    /// Writing it onto `estimatedArrival` would make the next hero treat
    /// a delay formula as a provider ETA.
    func testSchedulePlusDelayIsNotAbsorbedAsAProviderEstimate() {
        let scheduled = Date(timeIntervalSince1970: 1_788_377_700)
        let delay = 25
        let timetable = scheduled.addingTimeInterval(Double(delay) * 60)
        XCTAssertNil(LiveActivityPushSync.providerArrival(
            arrivalTime: timetable, scheduledArrival: scheduled, delayMinutes: delay))
        XCTAssertNil(LiveActivityPushSync.providerArrival(
            arrivalTime: scheduled, scheduledArrival: scheduled, delayMinutes: delay))
    }

    func testAirlineRevisionIsAbsorbedAsAProviderEstimate() {
        let scheduled = Date(timeIntervalSince1970: 1_788_377_700)
        let revised = Date(timeIntervalSince1970: 1_788_375_600)
        XCTAssertEqual(
            LiveActivityPushSync.providerArrival(
                arrivalTime: revised, scheduledArrival: scheduled, delayMinutes: 25),
            revised)
    }
}
