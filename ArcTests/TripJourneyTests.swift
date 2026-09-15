import XCTest
@testable import Arc

/// A journey is what My Trips draws one card for: a leg on its own, or the
/// legs a connection binds, in the list's own order.
@MainActor
final class TripJourneyTests: XCTestCase {
    private func leg(_ number: String, departsIn hours: Double) -> Flight {
        let dep = Date.now.addingTimeInterval(hours * 3600)
        let f = Flight(flightNumber: number, date: dep)
        f.scheduledDeparture = dep
        f.scheduledArrival = dep.addingTimeInterval(3600)
        f.status = .scheduled
        return f
    }

    func testUnconnectedLegsAreOneJourneyEach() {
        let a = leg("LX8", departsIn: 5), b = leg("LX14", departsIn: 50)
        let journeys = TripJourney.group([a, b], connections: [])
        XCTAssertEqual(journeys.map { $0.legs.map(\.flightNumber) }, [["LX8"], ["LX14"]])
    }

    func testAConnectionSharesOneCard() {
        let inbound = leg("GQ21", departsIn: 70), outbound = leg("LH1751", departsIn: 72)
        let later = leg("LX14", departsIn: 400)
        let journeys = TripJourney.group([inbound, outbound, later],
                                         connections: [(inbound: inbound, outbound: outbound)])
        XCTAssertEqual(journeys.map { $0.legs.map(\.flightNumber) }, [["GQ21", "LH1751"], ["LX14"]])
        XCTAssertEqual(journeys[0].id, inbound.id)
    }

    func testAChainOfConnectionsIsOneJourney() {
        let a = leg("A1", departsIn: 10), b = leg("B2", departsIn: 12), c = leg("C3", departsIn: 14)
        let journeys = TripJourney.group([a, b, c],
                                         connections: [(inbound: a, outbound: b), (inbound: b, outbound: c)])
        XCTAssertEqual(journeys.count, 1)
        XCTAssertEqual(journeys[0].legs.map(\.flightNumber), ["A1", "B2", "C3"])
    }

    /// A connection whose legs the list does not draw next to each other
    /// (another trip sits between them) stays apart: three cards, not two.
    func testConnectedLegsThatAreNotAdjacentStaySeparate() {
        let inbound = leg("GQ21", departsIn: 70), other = leg("LX8", departsIn: 71), outbound = leg("LH1751", departsIn: 72)
        let journeys = TripJourney.group([inbound, other, outbound],
                                         connections: [(inbound: inbound, outbound: outbound)])
        XCTAssertEqual(journeys.count, 3)
    }

    func testNoFlightsNoJourneys() {
        XCTAssertTrue(TripJourney.group([], connections: []).isEmpty)
    }

    /// The list pins an active outbound above its landed inbound, and the old
    /// spine never joined that order either.
    func testAnOutboundDrawnAboveItsInboundStaysApart() {
        let inbound = leg("GQ21", departsIn: 70), outbound = leg("LH1751", departsIn: 72)
        let journeys = TripJourney.group([outbound, inbound],
                                         connections: [(inbound: inbound, outbound: outbound)])
        XCTAssertEqual(journeys.count, 2)
    }
}
