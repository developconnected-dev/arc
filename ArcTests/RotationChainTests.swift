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

    // MARK: - Chain propagation

    private func rleg(_ number: String, from dep: String, to arr: String,
                      schedDep: String?, schedArr: String,
                      status: String = "scheduled", delay: Int = 0) -> RotationLeg {
        RotationLeg(flightNumber: number, depIATA: dep, arrIATA: arr,
                    scheduledArrival: DateHelpers.parseAPIDate(schedArr),
                    actualArrival: nil, delayMinutes: delay, status: status,
                    scheduledDeparture: schedDep.flatMap { DateHelpers.parseAPIDate($0) })
    }

    /// The scenario the single-leg view is blind to: the feeder is 50 minutes
    /// late this morning while tonight's inbound still reads "on time". The
    /// chain carries the lateness through the middle turnaround and predicts
    /// ~30 minutes; the old math would have said nothing at all.
    func testLatenessTwoLegsAwayPropagates() {
        let chain = [
            rleg("LX1571", from: "VIE", to: "ZRH",
                 schedDep: "2026-07-20T09:00:00.000Z", schedArr: "2026-07-20T11:00:00.000Z",
                 status: "active", delay: 50),
            rleg("LX1412", from: "ZRH", to: "BEG",
                 schedDep: "2026-07-20T12:00:00.000Z", schedArr: "2026-07-20T13:30:00.000Z"),
        ]
        // Single-leg view: inbound on time, lands 13:30, +35m turnaround →
        // ready 14:05 for a 14:00 departure → below the 10-min bar → silent.
        XCTAssertNil(RotationChain.predictDelay(
            inboundEffectiveArrival: DateHelpers.parseAPIDate("2026-07-20T13:30:00.000Z")!,
            scheduledDeparture: DateHelpers.parseAPIDate("2026-07-20T14:00:00.000Z")!,
            aircraftType: nil, officialDelayMinutes: 0))

        // Chain view, WITH the en-route recovery discount: the feeder is 50m
        // down on a 2h block, claws back min(25, 10% of block) = 12m, so it
        // lands 11:38 rather than 11:50 → ready 12:13 → LX1412 slips 13m →
        // lands 13:43 → ready 14:18 → 18 minutes late.
        let p = RotationChain.predictChainDelay(
            chain: chain,
            scheduledDeparture: DateHelpers.parseAPIDate("2026-07-20T14:00:00.000Z")!,
            aircraftType: nil, officialDelayMinutes: 0)
        XCTAssertEqual(p?.minutes, 18)
        XCTAssertTrue(p?.reason.contains("carries through") == true)
    }

    /// The discount the case above depends on, pinned on its own so a change
    /// to the recovery model fails HERE — naming the cause — rather than only
    /// as a surprising arithmetic slip two legs downstream.
    func testDelayedLegClawsBackSomeTimeEnRoute() {
        let leg = rleg("LX1571", from: "VIE", to: "ZRH",
                       schedDep: "2026-07-20T09:00:00.000Z", schedArr: "2026-07-20T11:00:00.000Z",
                       status: "active", delay: 50)
        // 50m down, 120m block → recovers min(25, 12) = 12m → 38m late.
        XCTAssertEqual(leg.effectiveArrival, DateHelpers.parseAPIDate("2026-07-20T11:38:00.000Z"))

        // The claw-back is capped, so a long-haul leg can't recover absurdly.
        let longHaul = rleg("LX40", from: "ZRH", to: "JFK",
                            schedDep: "2026-07-20T09:00:00.000Z", schedArr: "2026-07-20T18:00:00.000Z",
                            status: "active", delay: 60)
        // 540m block → 10% is 54, capped at 25 → 35m late, not 6m.
        XCTAssertEqual(longHaul.effectiveArrival, DateHelpers.parseAPIDate("2026-07-20T18:35:00.000Z"))
    }

    /// Ground-time slack absorbs small lateness: a 20-minute-late feeder with
    /// an hour on the ground in between is a non-event, and the chain must
    /// stay silent rather than cry wolf.
    func testGroundSlackAbsorbsSmallLateness() {
        let chain = [
            rleg("LX1571", from: "VIE", to: "ZRH",
                 schedDep: "2026-07-20T09:00:00.000Z", schedArr: "2026-07-20T11:00:00.000Z",
                 status: "active", delay: 20),
            rleg("LX1412", from: "ZRH", to: "BEG",
                 schedDep: "2026-07-20T12:00:00.000Z", schedArr: "2026-07-20T13:30:00.000Z"),
        ]
        XCTAssertNil(RotationChain.predictChainDelay(
            chain: chain,
            scheduledDeparture: DateHelpers.parseAPIDate("2026-07-20T14:15:00.000Z")!,
            aircraftType: nil, officialDelayMinutes: 0))
    }

    /// Legs cached before scheduledDeparture existed can't propagate — the
    /// math degrades to the immediate-inbound answer, never to a wrong one.
    func testMissingDepartureTimesDegradeGracefully() {
        let chain = [
            rleg("LX1571", from: "VIE", to: "ZRH",
                 schedDep: nil, schedArr: "2026-07-20T11:00:00.000Z",
                 status: "active", delay: 50),
            rleg("LX1412", from: "ZRH", to: "BEG",
                 schedDep: nil, schedArr: "2026-07-20T13:30:00.000Z",
                 status: "scheduled", delay: 42),
        ]
        // Propagation impossible; the inbound's own 42-min lateness still counts.
        let p = RotationChain.predictChainDelay(
            chain: chain,
            scheduledDeparture: DateHelpers.parseAPIDate("2026-07-20T14:00:00.000Z")!,
            aircraftType: nil, officialDelayMinutes: 0)
        XCTAssertEqual(p?.minutes, 47)   // 13:30+42m = 14:12 + 35m turnaround = 14:47
        XCTAssertTrue(p?.reason.contains("Inbound aircraft lands too late") == true)
    }

    /// A landed leg's actual time is the truth — no propagation on top of it.
    func testLandedLegsAreNotSecondGuessed() {
        let chain = [
            rleg("LX1571", from: "VIE", to: "ZRH",
                 schedDep: "2026-07-20T09:00:00.000Z", schedArr: "2026-07-20T11:00:00.000Z",
                 status: "active", delay: 90),
            RotationLeg(flightNumber: "LX1412", depIATA: "ZRH", arrIATA: "BEG",
                        scheduledArrival: DateHelpers.parseAPIDate("2026-07-20T13:30:00.000Z"),
                        actualArrival: DateHelpers.parseAPIDate("2026-07-20T13:32:00.000Z"),
                        delayMinutes: 2, status: "landed",
                        scheduledDeparture: DateHelpers.parseAPIDate("2026-07-20T12:00:00.000Z")),
        ]
        // The plane demonstrably made it: landed 13:32 → ready 14:07 for a
        // 14:00 departure → 7 minutes, under the bar → silent.
        XCTAssertNil(RotationChain.predictChainDelay(
            chain: chain,
            scheduledDeparture: DateHelpers.parseAPIDate("2026-07-20T14:00:00.000Z")!,
            aircraftType: nil, officialDelayMinutes: 0))
    }
}

// MARK: - Row wording (RotationLegDisplay)

/// The row draws a tick only for a landed leg; everything else names its state
/// from status + clock, and lateness appears only when there is some.
@MainActor
final class RotationLegDisplayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func leg(status: String, delay: Int = 0, depIn: Double, arrIn: Double,
                     actualArr: Double? = nil) -> RotationLeg {
        RotationLeg(flightNumber: "LX1412", depIATA: "ZRH", arrIATA: "BEG",
                    scheduledArrival: now.addingTimeInterval(arrIn * 60),
                    actualArrival: actualArr.map { now.addingTimeInterval($0 * 60) },
                    delayMinutes: delay, status: status,
                    scheduledDeparture: now.addingTimeInterval(depIn * 60))
    }

    func testAirborneLegIsNotATick() {
        let d = RotationLegDisplay.make(leg(status: "active", depIn: -60, arrIn: 40), now: now)
        XCTAssertEqual(d.phase, .airborne)
        XCTAssertEqual(d.symbol, "airplane")
        XCTAssertEqual(d.statusText, "In the air")
        XCTAssertEqual(d.timeCaption, "lands")
    }

    func testAirborneLateLegNamesTheLateness() {
        let d = RotationLegDisplay.make(leg(status: "active", delay: 22, depIn: -60, arrIn: 40), now: now)
        XCTAssertEqual(d.statusText, "In the air · 22m late")
        XCTAssertEqual(d.delayMinutes, 22)
    }

    func testLandedOnTimeIsTheOnlyTick() {
        let d = RotationLegDisplay.make(leg(status: "landed", depIn: -180, arrIn: -30, actualArr: -32), now: now)
        XCTAssertEqual(d.phase, .landed)
        XCTAssertEqual(d.symbol, "checkmark.circle.fill")
        XCTAssertEqual(d.statusText, "Landed on time")
        XCTAssertEqual(d.timeCaption, "landed")
    }

    func testLandedLate() {
        let d = RotationLegDisplay.make(leg(status: "landed", delay: 40, depIn: -180, arrIn: -30, actualArr: -5), now: now)
        XCTAssertEqual(d.statusText, "Landed · 40m late")
    }

    func testFutureLegIsScheduledWithDepartureTime() {
        let d = RotationLegDisplay.make(leg(status: "scheduled", depIn: 90, arrIn: 200), now: now)
        XCTAssertEqual(d.phase, .scheduled)
        XCTAssertEqual(d.symbol, "clock")
        XCTAssertTrue(d.statusText.hasPrefix("Departs "), d.statusText)
        XCTAssertEqual(d.timeCaption, "due")
    }

    /// Past its departure but the feed still says scheduled: not "Scheduled".
    func testPastDepartureStillScheduledIsUnconfirmed() {
        let d = RotationLegDisplay.make(leg(status: "scheduled", depIn: -25, arrIn: 60), now: now)
        XCTAssertEqual(d.statusText, "Departure not yet confirmed")
        XCTAssertEqual(d.symbol, "airplane.departure")
    }

    /// Past its arrival and never reported landed: the honest answer.
    func testPastArrivalNotLandedIsUnconfirmed() {
        for status in ["scheduled", "active"] {
            let d = RotationLegDisplay.make(leg(status: status, depIn: -200, arrIn: -45), now: now)
            XCTAssertEqual(d.phase, .overdue, status)
            XCTAssertEqual(d.statusText, "Landing not yet confirmed", status)
        }
    }

    /// Delay pushes the "departure passed" judgement, so a leg running 30m
    /// late that's 15m past its scheduled departure is still just late.
    func testDelayShiftsTheDepartureJudgement() {
        let d = RotationLegDisplay.make(leg(status: "scheduled", delay: 30, depIn: -15, arrIn: 90), now: now)
        XCTAssertEqual(d.phase, .scheduled)
        XCTAssertTrue(d.statusText.hasSuffix("· 30m late"), d.statusText)
    }

    func testCancelled() {
        let d = RotationLegDisplay.make(leg(status: "cancelled", depIn: 30, arrIn: 90), now: now)
        XCTAssertEqual(d.phase, .cancelled)
        XCTAssertNil(d.timeText)
    }
}
