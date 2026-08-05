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
        // Serbia → Switzerland → United States: leaves one control area for
        // another, and the onward leg is US-bound, which is screened separately.
        let a = flight("LX1413", from: "BEG", to: "ZRH", depOffsetMin: 60, durationMin: 120)
        let b = flight("LX8", from: "ZRH", to: "ORD", depOffsetMin: 270, durationMin: 570)
        let names = ConnectionPlanner.transferSteps(inbound: a, outbound: b).map(\.name)
        XCTAssertTrue(names.contains("Passport control"))
        XCTAssertTrue(names.contains("Security recheck"))
    }

    /// The reported bug. Syros → Athens → Munich changes country, so the old
    /// country-inequality test billed it for passport control AND a security
    /// recheck. Greece and Germany are both Schengen: there is no desk.
    func testSchengenTransferHasNoBorderFormalities() {
        let a = flight("GQ21", from: "JSY", to: "ATH", depOffsetMin: 60,
                       durationMin: 45, aircraft: "ATR 72-600")
        let b = flight("LH1751", from: "ATH", to: "MUC", depOffsetMin: 165, durationMin: 165)
        let names = ConnectionPlanner.transferSteps(inbound: a, outbound: b).map(\.name)
        XCTAssertFalse(names.contains("Passport control"))
        XCTAssertFalse(names.contains("Security recheck"))
        XCTAssertFalse(names.contains("Baggage reclaim & customs"))
        XCTAssertEqual(ConnectionPlanner.borderNote(inbound: a, outbound: b),
                       "Both legs stay inside the Schengen area — no passport control on this transfer.")

        // Deplane 8 + transfer walk 8 + walk to gate 7 + at gate 15. The card
        // used to ask for 67 minutes on this transfer — 15 of them for a
        // passport desk that isn't there and 10 for a screening that isn't
        // either — and so called a one-hour layover "Tight".
        let plan = ConnectionPlanner.plan(inbound: a, outbound: b)
        XCTAssertEqual(plan.neededMinutes, 38)
        XCTAssertEqual(ConnectionPlanner.risk(neededMinutes: plan.neededMinutes,
                                              layoverMinutes: 60), .normal)
    }

    /// Crossing a national border inside the Common Travel Area is still no
    /// border — the mirror image of the Schengen case.
    func testCommonTravelAreaTransferHasNoPassportControl() {
        let a = flight("EI3220", from: "ORK", to: "DUB", depOffsetMin: 60, durationMin: 50)
        let b = flight("EI152", from: "DUB", to: "MAN", depOffsetMin: 180, durationMin: 70)
        let names = ConnectionPlanner.transferSteps(inbound: a, outbound: b).map(\.name)
        XCTAssertFalse(names.contains("Passport control"))
    }

    /// Leaving Schengen genuinely does meet a desk — the fix must not have
    /// simply deleted the step.
    func testLeavingSchengenStillMeetsPassportControl() {
        let a = flight("LH1751", from: "ATH", to: "MUC", depOffsetMin: 60, durationMin: 165)
        let b = flight("LH2472", from: "MUC", to: "LHR", depOffsetMin: 300, durationMin: 130)
        let names = ConnectionPlanner.transferSteps(inbound: a, outbound: b).map(\.name)
        XCTAssertTrue(names.contains("Passport control"))
    }

    /// The expensive case a country comparison hides: every international
    /// arrival into the US reclaims its bags and clears customs before flying on.
    func testInternationalArrivalIntoUSReclaimsBags() {
        let a = flight("LX8", from: "ZRH", to: "ORD", depOffsetMin: 60, durationMin: 570)
        let b = flight("UA200", from: "ORD", to: "SFO", depOffsetMin: 750, durationMin: 270)
        let names = ConnectionPlanner.transferSteps(inbound: a, outbound: b).map(\.name)
        XCTAssertTrue(names.contains("Passport control"))
        XCTAssertTrue(names.contains("Baggage reclaim & customs"))
        XCTAssertTrue(names.contains("Security recheck"))
    }

    /// A US domestic connection reclaims nothing — the same hub, no border.
    func testUSDomesticConnectionDoesNotReclaimBags() {
        let a = flight("UA100", from: "BOS", to: "ORD", depOffsetMin: 60, durationMin: 150)
        let b = flight("UA200", from: "ORD", to: "SFO", depOffsetMin: 300, durationMin: 270)
        let names = ConnectionPlanner.transferSteps(inbound: a, outbound: b).map(\.name)
        XCTAssertFalse(names.contains("Baggage reclaim & customs"))
        XCTAssertFalse(names.contains("Security recheck"))
    }

    /// A code that isn't a known airport (a station, a port) must not be read
    /// as "a different country" and conjure a passport desk out of nothing.
    func testUnknownEndpointDoesNotInventABorder() {
        let a = flight("IC1", from: "ZZZ", to: "ATH", depOffsetMin: 60, durationMin: 120)
        let b = flight("LH1751", from: "ATH", to: "MUC", depOffsetMin: 240, durationMin: 165)
        let names = ConnectionPlanner.transferSteps(inbound: a, outbound: b).map(\.name)
        XCTAssertFalse(names.contains("Passport control"))
    }

    /// A turboprop empties faster than a narrowbody, which empties faster than
    /// a widebody — the step that used to be a flat 12 minutes for everything.
    func testDeplaneScalesWithAircraftSize() {
        let out = flight("LH1751", from: "ATH", to: "MUC", depOffsetMin: 300, durationMin: 165)
        func deplane(_ aircraft: String?) -> Int {
            let inb = flight("GQ21", from: "JSY", to: "ATH", depOffsetMin: 60,
                             durationMin: 45, aircraft: aircraft)
            return ConnectionPlanner.transferSteps(inbound: inb, outbound: out).first!.minutes
        }
        XCTAssertLessThan(deplane("ATR 72-600"), deplane("Airbus A320neo"))
        XCTAssertLessThan(deplane("Airbus A320neo"), deplane("Airbus A350-900"))
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

final class GateMatchTests: XCTestCase {
    private let gates = [
        FlightAPIClient.Gate(ref: "A54", lat: 47.4539, lon: 8.5618),
        FlightAPIClient.Gate(ref: "A55", lat: 47.4541, lon: 8.5620),
        FlightAPIClient.Gate(ref: "B 12", lat: 47.4550, lon: 8.5630),
    ]

    func testExactMatch() {
        XCTAssertEqual(FlightAPIClient.matchGate(gates, to: "A54")?.ref, "A54")
    }

    /// Airlines and OSM disagree about spacing ("B 12" vs "B12").
    func testMatchIgnoresSpacing() {
        XCTAssertEqual(FlightAPIClient.matchGate(gates, to: "B12")?.ref, "B 12")
    }

    /// Some airlines report bare numbers ("54") where OSM has "A54".
    func testDigitsFallback() {
        XCTAssertEqual(FlightAPIClient.matchGate(gates, to: "55")?.ref, "A55")
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(FlightAPIClient.matchGate(gates, to: "C99"))
    }
}

// MARK: - Measured data replacing heuristics

@MainActor
final class ConnectionMeasurementTests: XCTestCase {
    private func flight(_ number: String, from dep: String, to arr: String,
                        depOffsetMin: Double, durationMin: Double,
                        arrGate: String? = nil, depGate: String? = nil) -> Flight {
        let f = Flight(flightNumber: number, date: .now.addingTimeInterval(depOffsetMin * 60))
        f.departureIATA = dep; f.arrivalIATA = arr
        f.scheduledDeparture = .now.addingTimeInterval(depOffsetMin * 60)
        f.scheduledArrival = .now.addingTimeInterval((depOffsetMin + durationMin) * 60)
        f.arrivalGate = arrGate; f.departureGate = depGate
        return f
    }

    private var athToMuc: (Flight, Flight) {
        (flight("GQ21", from: "JSY", to: "ATH", depOffsetMin: 60, durationMin: 45),
         flight("LH1751", from: "ATH", to: "MUC", depOffsetMin: 165, durationMin: 165))
    }

    /// A walk is a distance, not an airport size tier.
    func testWalkMinutesScaleWithDistance() {
        XCTAssertLessThan(ConnectionPlanner.walkMinutes(meters: 200),
                          ConnectionPlanner.walkMinutes(meters: 1200))
        // Straight line is inflated for real corridors: 1 km is not 13 minutes.
        XCTAssertEqual(ConnectionPlanner.walkMinutes(meters: 1000), 18)
        // Never absurdly small, however close the gates are.
        XCTAssertGreaterThanOrEqual(ConnectionPlanner.walkMinutes(meters: 5), 3)
    }

    /// A measured distance replaces BOTH walking tiers — charging a separate
    /// "walk to gate" on top would count the same corridor twice.
    func testMeasuredWalkReplacesBothWalkingTiers() {
        let (a, b) = athToMuc
        var context = ConnectionPlanner.Context()
        context.gateDistanceMeters = 610
        context.fromGate = "A12"; context.toGate = "B24"
        let steps = ConnectionPlanner.transferSteps(inbound: a, outbound: b, context: context)
        let names = steps.map(\.name)
        XCTAssertTrue(names.contains("Walk A12 → B24"))
        XCTAssertFalse(names.contains("Transfer walk"))
        XCTAssertFalse(names.contains("Walk to gate"))
        XCTAssertEqual(steps.first { $0.name.hasPrefix("Walk") }?.detail, "610 m, gate to gate")
    }

    /// A gate from history is a habit, not an assignment, and has to say so.
    func testPredictedGatesAreLabelledAsSuch() {
        let (a, b) = athToMuc
        var context = ConnectionPlanner.Context()
        context.gateDistanceMeters = 400
        context.fromGate = "A12"; context.toGate = "B24"
        context.gatesPredicted = true
        let step = ConnectionPlanner.transferSteps(inbound: a, outbound: b, context: context)
            .first { $0.name.hasPrefix("Walk") }
        XCTAssertEqual(step?.detail, "400 m · gates A12–B24 are the usual pair")
    }

    /// No gates known — the old tiers must still be there.
    func testWithoutGatesTheHeuristicTiersRemain() {
        let (a, b) = athToMuc
        let names = ConnectionPlanner.transferSteps(inbound: a, outbound: b).map(\.name)
        XCTAssertTrue(names.contains("Transfer walk"))
        XCTAssertTrue(names.contains("Walk to gate"))
    }

    /// A live queue reading beats the tier — but only when it is a reading.
    func testLiveSecurityQueueIsUsedAndLabelled() {
        // ZRH → ORD crosses a control area and is US-bound, so a recheck exists.
        let a = flight("LX1413", from: "BEG", to: "ZRH", depOffsetMin: 60, durationMin: 120)
        let b = flight("LX8", from: "ZRH", to: "ORD", depOffsetMin: 270, durationMin: 570)
        var live = ConnectionPlanner.Context()
        live.securityMinutes = 22; live.securityIsLive = true; live.securityAgeMinutes = 4
        let step = ConnectionPlanner.transferSteps(inbound: a, outbound: b, context: live)
            .first { $0.name == "Security recheck" }
        XCTAssertEqual(step?.minutes, 22)
        XCTAssertEqual(step?.detail, "live queue · 4m ago")

        // The endpoint's time-of-day fallback is no better than our own tier,
        // so it must not be dressed up as a measurement.
        var estimated = ConnectionPlanner.Context()
        estimated.securityMinutes = 5; estimated.securityIsLive = false
        let fallback = ConnectionPlanner.transferSteps(inbound: a, outbound: b, context: estimated)
            .first { $0.name == "Security recheck" }
        XCTAssertNil(fallback?.detail)
        XCTAssertEqual(fallback?.minutes, 10)
    }

    // MARK: - Published minimums

    func testTransferKindClassification() {
        let dom = (flight("UA100", from: "BOS", to: "ORD", depOffsetMin: 60, durationMin: 150),
                   flight("UA200", from: "ORD", to: "SFO", depOffsetMin: 300, durationMin: 270))
        XCTAssertEqual(ConnectionPlanner.transferKind(inbound: dom.0, outbound: dom.1), .domestic)

        let (a, b) = athToMuc
        XCTAssertEqual(ConnectionPlanner.transferKind(inbound: a, outbound: b), .withinArea)

        let crossing = (flight("LX1413", from: "BEG", to: "ZRH", depOffsetMin: 60, durationMin: 120),
                        flight("LX8", from: "ZRH", to: "ORD", depOffsetMin: 270, durationMin: 570))
        XCTAssertEqual(ConnectionPlanner.transferKind(inbound: crossing.0, outbound: crossing.1),
                       .areaCrossing)
    }

    func testPublishedMinimumIsLookedUpForTheRightTransferKind() {
        // Munich asks more of a transfer that crosses a control area than of a
        // Schengen-to-Schengen one.
        XCTAssertEqual(AirportConnectTimes.publishedMinimum(at: "MUC", transfer: .withinArea), 35)
        XCTAssertEqual(AirportConnectTimes.publishedMinimum(at: "MUC", transfer: .areaCrossing), 45)
        // An airport we have no figure for produces no cross-check at all.
        XCTAssertNil(AirportConnectTimes.publishedMinimum(at: "JSY", transfer: .domestic))
    }

    func testLayoverUnderThePublishedMinimumIsFlagged() {
        // Athens, Schengen→Schengen, published minimum 45. A 30-minute layover
        // is shorter than anyone would sell.
        let a = flight("GQ21", from: "JSY", to: "ATH", depOffsetMin: 60, durationMin: 45)
        let b = flight("LH1751", from: "ATH", to: "MUC", depOffsetMin: 135, durationMin: 165)
        let plan = ConnectionPlanner.plan(inbound: a, outbound: b)
        XCTAssertEqual(plan.publishedMinimum, 45)
        XCTAssertEqual(plan.layoverMinutes, 30)
        XCTAssertTrue(plan.isBelowPublishedMinimum)
    }

    func testComfortableLayoverClearsThePublishedMinimum() {
        let (a, b) = athToMuc          // 60-minute layover at ATH, minimum 45
        let plan = ConnectionPlanner.plan(inbound: a, outbound: b)
        XCTAssertFalse(plan.isBelowPublishedMinimum)
    }

    /// No table entry must mean no claim, not a false all-clear.
    func testUnknownAirportMakesNoClaimEitherWay() {
        let a = flight("GQ100", from: "MUC", to: "JSY", depOffsetMin: 60, durationMin: 165)
        let b = flight("GQ21", from: "JSY", to: "ATH", depOffsetMin: 135, durationMin: 45)
        let plan = ConnectionPlanner.plan(inbound: a, outbound: b)
        XCTAssertNil(plan.publishedMinimum)
        XCTAssertFalse(plan.isBelowPublishedMinimum)
    }
}
