import XCTest
@testable import Arc

@MainActor
final class ConnectionPlannerTests: XCTestCase {
    private func flight(_ number: String, from dep: String, to arr: String,
                        depOffsetMin: Double, durationMin: Double,
                        status: FlightStatus = .scheduled,
                        aircraft: String? = nil, delay: Int = 0) -> Flight {
        let f = Flight(flightNumber: number, date: .now.addingTimeInterval(depOffsetMin * 60))
        f.departureIATA = dep; f.arrivalIATA = arr
        f.scheduledDeparture = .now.addingTimeInterval(depOffsetMin * 60)
        f.scheduledArrival = .now.addingTimeInterval((depOffsetMin + durationMin) * 60)
        f.status = status
        f.aircraftType = aircraft
        f.delayMinutes = delay
        return f
    }

    // MARK: - Detection

    func testDetectsAdjacentLegsThroughSameAirport() {
        let a = flight("LX1413", from: "BEG", to: "ZRH", depOffsetMin: 60, durationMin: 120)
        let b = flight("LX8", from: "ZRH", to: "ORD", depOffsetMin: 60 + 120 + 90, durationMin: 570)
        let pair = ConnectionPlanner.detectConnection(from: [b, a])   // order-independent
        XCTAssertEqual(pair?.inbound.flightNumber, "LX1413")
        XCTAssertEqual(pair?.outbound.flightNumber, "LX8")
    }

    func testNoConnectionAcrossDifferentAirports() {
        let a = flight("LX1413", from: "BEG", to: "ZRH", depOffsetMin: 60, durationMin: 120)
        let b = flight("BA713", from: "LHR", to: "JFK", depOffsetMin: 300, durationMin: 480)
        XCTAssertNil(ConnectionPlanner.detectConnection(from: [a, b]))
    }

    func testNoConnectionWhenGapAbsurd() {
        let a = flight("LX1413", from: "BEG", to: "ZRH", depOffsetMin: 60, durationMin: 120)
        // 3 days later — a separate trip, not a connection
        let b = flight("LX8", from: "ZRH", to: "ORD", depOffsetMin: 60 + 120 + 3 * 24 * 60, durationMin: 570)
        XCTAssertNil(ConnectionPlanner.detectConnection(from: [a, b]))
    }

    // MARK: - Steps

    func testBorderCrossingAddsPassportAndSecurity() {
        let a = flight("LX1413", from: "BEG", to: "ZRH", depOffsetMin: 60, durationMin: 120)
        let b = flight("LX8", from: "ZRH", to: "ORD", depOffsetMin: 270, durationMin: 570)
        let names = ConnectionPlanner.transferSteps(inbound: a, outbound: b).map(\.name)
        XCTAssertTrue(names.contains("Passport control"))
        XCTAssertTrue(names.contains("Security recheck"))
    }

    func testDomesticConnectionSkipsPassport() {
        // US domestic through a US hub: no border crossed anywhere.
        let a = flight("UA100", from: "BOS", to: "ORD", depOffsetMin: 60, durationMin: 150)
        let b = flight("UA200", from: "ORD", to: "SFO", depOffsetMin: 300, durationMin: 270)
        let names = ConnectionPlanner.transferSteps(inbound: a, outbound: b).map(\.name)
        XCTAssertFalse(names.contains("Passport control"))
    }

    func testWidebodyInboundTakesLongerToDeplane() {
        let narrow = flight("LX1413", from: "BEG", to: "ZRH", depOffsetMin: 60, durationMin: 120, aircraft: "Airbus A220-300")
        let wide = flight("LX92", from: "BEG", to: "ZRH", depOffsetMin: 60, durationMin: 120, aircraft: "Airbus A340-300")
        let out = flight("LX8", from: "ZRH", to: "ORD", depOffsetMin: 270, durationMin: 570)
        let deplaneNarrow = ConnectionPlanner.transferSteps(inbound: narrow, outbound: out).first!
        let deplaneWide = ConnectionPlanner.transferSteps(inbound: wide, outbound: out).first!
        XCTAssertLessThan(deplaneNarrow.minutes, deplaneWide.minutes)
    }

    // MARK: - Risk tiers

    func testRiskTiers() {
        XCTAssertEqual(ConnectionPlanner.risk(neededMinutes: 60, layoverMinutes: 120), .relaxed)
        XCTAssertEqual(ConnectionPlanner.risk(neededMinutes: 60, layoverMinutes: 70), .normal)
        XCTAssertEqual(ConnectionPlanner.risk(neededMinutes: 60, layoverMinutes: 50), .tight)
        XCTAssertEqual(ConnectionPlanner.risk(neededMinutes: 60, layoverMinutes: 30), .risky)
    }

    /// A delay on the inbound leg shrinks the layover and can flip the tier —
    /// the live property the notification watch depends on.
    func testInboundDelayShrinksLayover() {
        let a = flight("LX1413", from: "BEG", to: "ZRH", depOffsetMin: 60, durationMin: 120)
        let b = flight("LX8", from: "ZRH", to: "ORD", depOffsetMin: 60 + 120 + 90, durationMin: 570)
        let before = ConnectionPlanner.plan(inbound: a, outbound: b)
        a.delayMinutes = 45
        let after = ConnectionPlanner.plan(inbound: a, outbound: b)
        XCTAssertEqual(before.layoverMinutes - after.layoverMinutes, 45)
    }
}
