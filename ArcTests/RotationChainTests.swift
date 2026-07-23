import XCTest
@testable import Arc

final class RotationChainTests: XCTestCase {
    private func leg(_ number: String, from dep: String, to arr: String,
                     depScheduled: String, arrScheduled: String,
                     status: String = "landed", delay: Int = 0,
                     arrActual: String? = nil) -> FlightAPIClient.FlightSearchResult {
        .init(flight_number: number, airline_name: "Swiss", airline_iata: "LX",
              dep_iata: dep, arr_iata: arr, dep_city: nil, arr_city: nil,
              dep_scheduled: depScheduled, arr_scheduled: arrScheduled,
              dep_actual: nil, arr_actual: arrActual,
              status: status, dep_gate: nil, dep_terminal: nil, arr_gate: nil,
              arr_terminal: nil, arr_baggage: nil, delay: delay,
              aircraft_type: nil, aircraft_registration: nil, aircraft_icao24: nil,
              dep_lat: nil, dep_lon: nil, arr_lat: nil, arr_lon: nil)
    }

    private let myDeparture = DateHelpers.parseAPIDate("2026-07-20T18:00:00.000Z")!

    // MARK: - Chain building

    /// The tail flew VIE→ZRH→BEG→ZRH today before becoming my ZRH departure —
    /// the chain must link each leg to the airport the next one left from,
    /// in chronological order.
    func testBuildsMultiLegChainInChronologicalOrder() {
        let legs = [
            leg("LX1413", from: "BEG", to: "ZRH", depScheduled: "2026-07-20T14:00:00.000Z", arrScheduled: "2026-07-20T16:00:00.000Z"),
            leg("LX1412", from: "ZRH", to: "BEG", depScheduled: "2026-07-20T10:30:00.000Z", arrScheduled: "2026-07-20T12:30:00.000Z"),
            leg("LX1571", from: "VIE", to: "ZRH", depScheduled: "2026-07-20T07:00:00.000Z", arrScheduled: "2026-07-20T08:30:00.000Z"),
        ]
        let chain = RotationChain.buildChain(
            from: legs, endingAt: "ZRH", before: myDeparture, excludingFlightNumber: "LX188")
        XCTAssertEqual(chain.map(\.flightNumber), ["LX1571", "LX1412", "LX1413"])
    }

    func testChainExcludesOwnFlightAndUnrelatedAirports() {
        let legs = [
            leg("LX188", from: "BEG", to: "ZRH", depScheduled: "2026-07-20T14:00:00.000Z", arrScheduled: "2026-07-20T16:00:00.000Z"),
            leg("LX999", from: "CDG", to: "LHR", depScheduled: "2026-07-20T09:00:00.000Z", arrScheduled: "2026-07-20T10:00:00.000Z"),
        ]
        let chain = RotationChain.buildChain(
            from: legs, endingAt: "ZRH", before: myDeparture, excludingFlightNumber: "LX188")
        XCTAssertTrue(chain.isEmpty)
    }

    func testChainCapsAtMaxLegs() {
        // 6 plausible back-to-back ZRH↔BEG shuttles; only the 4 most recent survive.
        var legs: [FlightAPIClient.FlightSearchResult] = []
        for i in 0..<6 {
            let dep = String(format: "2026-07-20T%02d:00:00.000Z", 4 + i * 2)
            let arr = String(format: "2026-07-20T%02d:00:00.000Z", 5 + i * 2)
            let (from, to) = i % 2 == 0 ? ("BEG", "ZRH") : ("ZRH", "BEG")
            legs.append(leg("LX\(100 + i)", from: from, to: to, depScheduled: dep, arrScheduled: arr))
        }
        let chain = RotationChain.buildChain(
            from: legs, endingAt: "ZRH", before: myDeparture, excludingFlightNumber: "LX999")
        XCTAssertEqual(chain.count, 4)
    }

    // MARK: - Turnaround table

    func testTurnaroundTiers() {
        XCTAssertEqual(RotationChain.turnaroundMinutes(for: "Airbus A330-300"), 60)
        XCTAssertEqual(RotationChain.turnaroundMinutes(for: "Airbus A220-100"), 30)
        XCTAssertEqual(RotationChain.turnaroundMinutes(for: "Airbus A320neo"), 35)
        XCTAssertEqual(RotationChain.turnaroundMinutes(for: nil), 35)
    }

    // MARK: - Prediction

    /// Inbound lands 17:50, A320 needs 35m → can't leave before 18:25, i.e.
    /// 25m after the 18:00 schedule the airline still claims is on time.
    func testPredictsKnockOnDelayWhenTurnaroundImpossible() {
        let eta = DateHelpers.parseAPIDate("2026-07-20T17:50:00.000Z")!
        let p = RotationChain.predictDelay(
            inboundEffectiveArrival: eta, scheduledDeparture: myDeparture,
            aircraftType: "Airbus A320", officialDelayMinutes: 0)
        XCTAssertEqual(p?.minutes, 25)
    }

    func testNoPredictionWhenInboundComfortablyEarly() {
        let eta = DateHelpers.parseAPIDate("2026-07-20T16:00:00.000Z")!
        XCTAssertNil(RotationChain.predictDelay(
            inboundEffectiveArrival: eta, scheduledDeparture: myDeparture,
            aircraftType: "Airbus A320", officialDelayMinutes: 0))
    }

    /// If the airline already admits MORE than we'd predict, our number adds
    /// nothing — stay silent rather than argue downward.
    func testNoPredictionWhenAirlineAlreadyKnowsMore() {
        let eta = DateHelpers.parseAPIDate("2026-07-20T17:50:00.000Z")!
        XCTAssertNil(RotationChain.predictDelay(
            inboundEffectiveArrival: eta, scheduledDeparture: myDeparture,
            aircraftType: "Airbus A320", officialDelayMinutes: 20))
    }

    func testNoPredictionForImplausiblyHugeGap() {
        let eta = DateHelpers.parseAPIDate("2026-07-21T04:00:00.000Z")!   // 10h after schedule
        XCTAssertNil(RotationChain.predictDelay(
            inboundEffectiveArrival: eta, scheduledDeparture: myDeparture,
            aircraftType: "Airbus A320", officialDelayMinutes: 0))
    }

    /// RotationLeg.effectiveArrival prefers the actual over scheduled+delay.
    func testEffectiveArrivalPrefersActual() {
        let l = RotationLeg(
            flightNumber: "LX1", depIATA: "VIE", arrIATA: "ZRH",
            scheduledArrival: DateHelpers.parseAPIDate("2026-07-20T16:00:00.000Z"),
            actualArrival: DateHelpers.parseAPIDate("2026-07-20T16:42:00.000Z"),
            delayMinutes: 10, status: "landed")
        XCTAssertEqual(l.effectiveArrival, DateHelpers.parseAPIDate("2026-07-20T16:42:00.000Z"))
    }
}
