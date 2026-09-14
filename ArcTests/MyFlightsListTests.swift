import XCTest
@testable import Arc

/// The row that just landed is the confirmation of an add — so the list must
/// know which row that is, in its own order, to bring it into view.
@MainActor
final class MyFlightsListTests: XCTestCase {
    private func makeFlight(_ number: String, departsIn hours: Double, status: FlightStatus = .scheduled) -> Flight {
        let dep = Date.now.addingTimeInterval(hours * 3600)
        let f = Flight(flightNumber: number, date: dep)
        f.scheduledDeparture = dep
        f.scheduledArrival = dep.addingTimeInterval(2 * 3600)
        f.status = status
        return f
    }

    /// A batch that saved several legs reveals the one the list shows first:
    /// an active leg outranks an upcoming one whatever order they were saved in.
    func testRevealsTheTopmostLandedRowInListOrder() {
        let airborne = makeFlight("LH400", departsIn: -3, status: .active)
        let tomorrow = makeFlight("LX8", departsIn: 20)
        let nextWeek = makeFlight("GQ873", departsIn: 24 * 7)

        let target = MyFlightsView.rowToReveal([tomorrow, airborne], among: [nextWeek, tomorrow, airborne])

        XCTAssertEqual(target, airborne.id)
    }

    /// A trip the list doesn't show — a hand-logged past flight — has no row
    /// to scroll to; the list must not jump anywhere for it.
    func testALandedTripTheListDoesNotShowHasNoRow() {
        let past = makeFlight("LX1056", departsIn: -24 * 17, status: .landed)
        let upcoming = makeFlight("LX8", departsIn: 20)

        XCTAssertNil(MyFlightsView.rowToReveal([past], among: [past, upcoming]))
    }

    /// The pure ordering the list draws: active first, then recently landed,
    /// then upcoming by soonest — the same rule the reveal target reads.
    func testListedOrderPinsActiveAboveUpcomingBySoonest() {
        let airborne = makeFlight("LH400", departsIn: -3, status: .active)
        let tomorrow = makeFlight("LX8", departsIn: 20)
        let nextWeek = makeFlight("GQ873", departsIn: 24 * 7)
        let past = makeFlight("LX1056", departsIn: -24 * 17, status: .landed)

        let listed = MyFlightsView.listed([nextWeek, past, tomorrow, airborne])

        XCTAssertEqual(listed.map(\.flightNumber), ["LH400", "LX8", "GQ873"])
    }
    func testManualBriefDoesNotClaimLiveMonitoring() {
        let flight = makeFlight("LX17", departsIn: 12)
        flight.dataTier = .manual
        let brief = JourneyBrief(flight)
        XCTAssertEqual(brief.title, "Your plans, together")
        XCTAssertTrue(brief.message.hasPrefix("Added by you."))
    }

    func testFerryBriefNamesTimetableInsteadOfPunctuality() {
        let flight = makeFlight("BLUE STAR", departsIn: 48)
        flight.mode = .sea
        flight.dataTier = .scheduled
        XCTAssertTrue(JourneyBrief(flight).message.hasPrefix("Based on the published timetable."))
    }

    func testRailBriefUsesPlatformVocabulary() {
        let flight = makeFlight("ICE373", departsIn: 2)
        flight.mode = .rail
        flight.departureGate = "7"
        XCTAssertTrue(JourneyBrief(flight).message.hasPrefix("Platform 7."))
    }

    func testCancellationUncertaintyOutranksGateAdvice() {
        let flight = makeFlight("LX17", departsIn: 2)
        flight.departureGate = "A12"
        flight.cancelUncertain = true
        let brief = JourneyBrief(flight)
        XCTAssertEqual(brief.title, "Worth checking")
        XCTAssertTrue(brief.message.contains("possible cancellation"))
        XCTAssertFalse(brief.message.contains("A12"))
    }

}
