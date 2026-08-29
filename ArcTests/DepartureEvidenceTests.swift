import XCTest
@testable import Arc
import SwiftUI

/// The question every Arc surface has to answer honestly: has this flight
/// actually left the ground?
///
/// The incident these tests exist for: a traveller boarded on time, the
/// aircraft pushed back on time, and then sat in an ATC hold for 35 minutes.
/// No airline feed calls that a delay — the flight was off-block on schedule
/// — so every surface that trusted the clock announced "In Flight" while she
/// was still on the tarmac. Gate time is not take-off time, and the gap
/// between them is the taxi, which nobody publishes.
///
/// Four user-facing states, and only the last one is In Air:
///   1. Departing — past the gate, no fresh ground roll. Ground layout.
///   2. Taxiing — we saw on-ground speed, held through at_gate until the
///      expected-wheels-up clock. Ground layout.
///   3. Takeoff unconfirmed — past expected wheels-up, no witness. Ground
///      layout. Never muted "In Air".
///   4. In air — only with a real witness: actualDeparture or a fresh
///      airborne sample. Airborne chrome.
final class DepartureEvidenceTests: XCTestCase {

    private let offBlock = Date(timeIntervalSince1970: 1_800_000_000)

    private func evidence(
        estimatedTakeoff: Date? = nil,
        actualDeparture: Date? = nil,
        groundState: String? = nil,
        groundObservedAt: Date? = nil,
        taxiStartedAt: Date? = nil,
        lastSeenOnGround: Date? = nil,
        taxiPriorMinutes: Int = 20,
        isLiveCovered: Bool = true
    ) -> DepartureEvidence {
        DepartureEvidence(
            offBlock: offBlock,
            estimatedTakeoff: estimatedTakeoff,
            actualDeparture: actualDeparture,
            groundState: groundState,
            groundObservedAt: groundObservedAt,
            taxiStartedAt: taxiStartedAt,
            lastSeenOnGround: lastSeenOnGround,
            taxiPriorMinutes: taxiPriorMinutes,
            isLiveCovered: isLiveCovered)
    }

    private func at(_ minutes: Double) -> Date { offBlock.addingTimeInterval(minutes * 60) }

    // MARK: - The baseline: no evidence at all, only the timetable

    func testBeforeOffBlockNothingHasDeparted() {
        let phase = evidence().phase(at: at(-5))
        XCTAssertEqual(phase, .beforeDeparture)
        XCTAssertFalse(phase.isOffTheGround)
        XCTAssertNil(phase.groundHeroTitle(mode: .air))
    }

    func testInsideTheTaxiWindowItIsDepartingNotAirborne() {
        let e = evidence()
        XCTAssertEqual(e.phase(at: at(1)), .departing)
        XCTAssertEqual(e.phase(at: at(19)), .departing)
        XCTAssertEqual(e.phase(at: at(1)).groundHeroTitle(mode: .air), "Departing…")
        XCTAssertFalse(e.phase(at: at(1)).isOffTheGround)
    }

    /// Past the expected wheels-up with nobody confirming anything: Takeoff
    /// unconfirmed, ground layout, never In Air.
    func testPastExpectedWheelsUpItIsPresumedNotConfirmed() {
        let phase = evidence().phase(at: at(21))
        XCTAssertEqual(phase, .presumedAirborne)
        XCTAssertFalse(phase.isOffTheGround)
        XCTAssertFalse(phase.isConfirmed)
        XCTAssertEqual(phase.groundHeroTitle(mode: .air), "Takeoff unconfirmed")
    }

    // MARK: - The incident: a long taxi at a busy airport

    /// The airport's learned taxi-out is what the hedge is measured against.
    /// At a hub that taxis 35 minutes, minute 25 is still on the ground.
    func testALearnedTaxiPriorHoldsTheHedgeOpenLongerAtASlowAirport() {
        let slow = evidence(taxiPriorMinutes: 35)
        XCTAssertEqual(slow.phase(at: at(25)), .departing)
        XCTAssertEqual(slow.phase(at: at(36)), .presumedAirborne)
        XCTAssertFalse(slow.phase(at: at(36)).isOffTheGround)
    }

    /// A taxi sample is Taxiing until the expected-wheels-up clock, not after.
    /// Fresh rolling after that clock is still not a takeoff witness.
    func testTaxiingDoesNotSurviveTheWheelsUpClock() {
        let e = evidence(groundState: "taxiing", groundObservedAt: at(38), taxiStartedAt: at(6))
        XCTAssertEqual(e.phase(at: at(40)), .presumedAirborne)
        XCTAssertFalse(e.phase(at: at(40)).isOffTheGround)
        XCTAssertEqual(e.phase(at: at(15)), .taxiing(since: at(6)))
    }

    /// Past the gate, a fresh at-the-stand sample with no roll is Departing —
    /// until the wheels-up clock forces Takeoff unconfirmed.
    func testFreshAtGateObservationIsDepartingUntilTheClock() {
        let e = evidence(groundState: "at_gate", groundObservedAt: at(12))
        XCTAssertEqual(e.phase(at: at(14)), .departing)
        XCTAssertEqual(e.phase(at: at(55)), .presumedAirborne)
        XCTAssertFalse(e.phase(at: at(55)).isOffTheGround)
    }

    /// Most of a long taxi is spent stopped in the queue for the runway.
    /// Having started to roll, a stationary sample is still the taxi — until
    /// the wheels-up clock, which must not invent a new verb mid-taxi, and
    /// must not linger on Taxiing afterwards.
    func testAPauseInTheQueueIsStillTaxiingUntilWheelsUp() {
        let e = evidence(groundState: "at_gate", groundObservedAt: at(18), taxiStartedAt: at(6))
        XCTAssertEqual(e.phase(at: at(19)), .taxiing(since: at(6)))
        XCTAssertEqual(e.phase(at: at(19)).groundHeroTitle(mode: .air), "Taxiing…")
        XCTAssertEqual(e.phase(at: at(21)), .presumedAirborne)
        XCTAssertFalse(e.phase(at: at(21)).isOffTheGround)
    }

    /// Evidence rots. An hour-old sighting says nothing about now, so the
    /// clock takes over again rather than pinning the flight to the gate.
    func testStaleGroundObservationStopsCounting() {
        let e = evidence(groundState: "taxiing", groundObservedAt: at(10), taxiStartedAt: at(6))
        XCTAssertEqual(e.phase(at: at(80)), .presumedAirborne)
        XCTAssertFalse(e.phase(at: at(80)).isOffTheGround)
    }

    /// Once rolling, keep saying Taxiing even if the latest sample has gone
    /// stale — don't flip Taxiing → Departing mid-taxi. The wheels-up clock
    /// is what ends it.
    func testStaleTaxiingBeforeWheelsUpStaysTaxiing() {
        let e = evidence(groundState: "taxiing", groundObservedAt: at(1), taxiStartedAt: at(1))
        XCTAssertEqual(e.phase(at: at(17)), .taxiing(since: at(1)))
    }

    // MARK: - Confirmation ends every hedge

    func testAReportedDepartureIsAirborne() {
        let e = evidence(actualDeparture: at(24))
        let phase = e.phase(at: at(25))
        XCTAssertEqual(phase, .airborne)
        XCTAssertTrue(phase.isOffTheGround)
        XCTAssertTrue(phase.isConfirmed)
        XCTAssertNil(phase.groundHeroTitle(mode: .air))
    }

    func testAnAirborneSightingIsAirborne() {
        let e = evidence(groundState: "airborne", groundObservedAt: at(23))
        let phase = e.phase(at: at(24))
        XCTAssertEqual(phase, .airborne)
        XCTAssertTrue(phase.isOffTheGround)
    }

    /// A witness jumps straight to In Air. No linger on Takeoff unconfirmed.
    func testAWitnessJumpsStraightToInAirPastWheelsUp() {
        let byRunway = evidence(actualDeparture: at(24))
        XCTAssertEqual(byRunway.phase(at: at(25)), .airborne)
        let bySample = evidence(groundState: "airborne", groundObservedAt: at(22))
        XCTAssertEqual(bySample.phase(at: at(24)), .airborne)
    }

    /// A take-off can only be confirmed once it has happened: a confirmation
    /// timestamped in the future is a filing, not a fact.
    func testAFutureDepartureTimestampIsNotAConfirmation() {
        let e = evidence(actualDeparture: at(30))
        XCTAssertEqual(e.phase(at: at(10)), .departing)
    }

    // MARK: - expectedWheelsUp

    func testExpectedWheelsUpTakesTheLatestOfWhatIsKnown() {
        XCTAssertEqual(evidence().expectedWheelsUp, at(20))
        // The provider's own estimate, when it is further out than the prior.
        XCTAssertEqual(evidence(estimatedTakeoff: at(31)).expectedWheelsUp, at(31))
        // …but never pulls the moment earlier than the airport's taxi-out.
        XCTAssertEqual(evidence(estimatedTakeoff: at(4)).expectedWheelsUp, at(20))
        // A witness that saw it on the ground at minute 30 restarts the clock.
        XCTAssertEqual(evidence(lastSeenOnGround: at(30)).expectedWheelsUp, at(50))
    }

    /// Without live coverage no confirmation can ever arrive, so a refresh
    /// that merely failed to mention a departure is not a sighting on the
    /// ground — treating it as one would hedge forever.
    func testWithoutLiveCoverageASilentRefreshIsNotEvidence() {
        let e = evidence(lastSeenOnGround: at(30), isLiveCovered: false)
        XCTAssertEqual(e.expectedWheelsUp, at(20))
        XCTAssertEqual(e.phase(at: at(35)), .presumedAirborne)
        XCTAssertFalse(e.phase(at: at(35)).isOffTheGround)
    }

    /// A stream of "still nothing" refreshes must not push the commitment
    /// out for ever; after the cap Arc presumes rather than hedges.
    func testTheSlidingHedgeIsCapped() {
        let e = evidence(lastSeenOnGround: at(200))
        XCTAssertEqual(e.expectedWheelsUp, offBlock.addingTimeInterval(DepartureEvidence.hardCap))
        XCTAssertEqual(e.phase(at: at(95)), .presumedAirborne)
        XCTAssertFalse(e.phase(at: at(95)).isOffTheGround)
    }

    // MARK: - What the surfaces ask

    func testHedgingIsExactlyTheUnconfirmedStates() {
        XCTAssertTrue(evidence().phase(at: at(5)).isHedged)
        XCTAssertTrue(evidence(groundState: "taxiing", groundObservedAt: at(5)).phase(at: at(6)).isHedged)
        XCTAssertTrue(evidence().phase(at: at(60)).isHedged)
        XCTAssertFalse(evidence(actualDeparture: at(24)).phase(at: at(25)).isHedged)
        XCTAssertFalse(evidence().phase(at: at(-5)).isHedged)
    }

    func testOffTheGroundIsOnlyAConfirmedTakeoff() {
        XCTAssertFalse(evidence().phase(at: at(5)).isOffTheGround)
        XCTAssertFalse(evidence(groundState: "taxiing", groundObservedAt: at(5)).phase(at: at(6)).isOffTheGround)
        XCTAssertFalse(evidence().phase(at: at(60)).isOffTheGround,
                       "presumed takeoff must keep ground layout")
        XCTAssertTrue(evidence(actualDeparture: at(24)).phase(at: at(25)).isOffTheGround)
        XCTAssertTrue(evidence(groundState: "airborne", groundObservedAt: at(24)).phase(at: at(25)).isOffTheGround)
    }

    func testHeroCopyMatchesTheFourStates() {
        XCTAssertEqual(evidence().phase(at: at(5)).groundHeroTitle(mode: .air), "Departing…")
        XCTAssertEqual(evidence(groundState: "taxiing", groundObservedAt: at(5), taxiStartedAt: at(2))
            .phase(at: at(6)).groundHeroTitle(mode: .air), "Taxiing…")
        XCTAssertEqual(evidence().phase(at: at(21)).groundHeroTitle(mode: .air), "Takeoff unconfirmed")
        XCTAssertEqual(DeparturePhase.takeoffUnconfirmedSubtitle, "We'll confirm when we have a signal.")
        XCTAssertNil(evidence(actualDeparture: at(24)).phase(at: at(25)).groundHeroTitle(mode: .air))
    }

    /// Airplane mode: no new facts will arrive until reconnect. Hours past
    /// expected wheels-up with no actualDeparture and no airborne sample
    /// must stay Takeoff unconfirmed on ground layout. The clock is not a
    /// witness, and there is no on-device detector in this contract.
    func testAirplaneModeSitsOnTakeoffUnconfirmedUntilANetworkWitness() {
        let dark = evidence()
        XCTAssertEqual(dark.phase(at: at(180)), .presumedAirborne)
        XCTAssertFalse(dark.phase(at: at(180)).isOffTheGround)
        XCTAssertFalse(dark.phase(at: at(180)).isConfirmed)
        XCTAssertEqual(dark.phase(at: at(180)).groundHeroTitle(mode: .air), "Takeoff unconfirmed")
        let afterReconnect = evidence(actualDeparture: at(24))
        XCTAssertEqual(afterReconnect.phase(at: at(180)), .airborne)
        XCTAssertTrue(afterReconnect.phase(at: at(180)).isOffTheGround)
    }
}

/// The same evidence, as the app's own screens read it.
final class FlightDepartureDisplayTests: XCTestCase {

    private func flight(minutesPastGate: Double, taxiPrior: Int = 20) -> Flight {
        let f = Flight(flightNumber: "LX1950", date: .now.addingTimeInterval(-minutesPastGate * 60))
        f.scheduledArrival = .now.addingTimeInterval(90 * 60)
        f.status = .active
        f.taxiPriorMinutes = taxiPrior
        return f
    }

    /// The incident, on the detail screen: 25 minutes past the gate time at
    /// an airport that takes 35 minutes to taxi. Nothing may read as flying.
    func testALongTaxiNeverReadsAsInAir() {
        let f = flight(minutesPastGate: 25, taxiPrior: 35)
        XCTAssertEqual(f.departurePhase, .departing)
        XCTAssertEqual(f.statusText, "Departing…")
        XCTAssertEqual(f.bannerHeadline, "Departing…")
        XCTAssertTrue(f.isDepartingUnconfirmed)
        XCTAssertFalse(f.departurePhase.isOffTheGround)
        XCTAssertFalse(f.statusText.contains("In Air"))
    }

    func testSeenRollingSaysTaxiing() {
        let f = flight(minutesPastGate: 12)
        f.recordGroundSample(onGround: true, velocity: 8, altitude: 0)
        XCTAssertEqual(f.statusText, "Taxiing…")
        XCTAssertEqual(f.bannerHeadline, "Taxiing…", "no duration worth printing in the first minute")
        XCTAssertNotNil(f.taxiElapsed)
        // Once it has gone on a while, the banner carries the number a person
        // in seat 14B actually wants.
        f.taxiStartedAt = .now.addingTimeInterval(-13 * 60)
        XCTAssertEqual(f.bannerHeadline, "Taxiing · 13m")
    }

    /// Past the expected wheels-up with nobody confirming: Takeoff
    /// unconfirmed, ground layout, never muted In Air.
    func testPresumedAirborneIsTakeoffUnconfirmedNotMutedInAir() {
        let f = flight(minutesPastGate: 45)
        XCTAssertEqual(f.departurePhase, .presumedAirborne)
        XCTAssertEqual(f.statusText, "Takeoff unconfirmed")
        XCTAssertEqual(f.bannerHeadline, "Takeoff unconfirmed")
        XCTAssertEqual(f.bannerColor, Color(.secondaryLabel))
        XCTAssertFalse(f.isDepartureConfirmed)
        XCTAssertFalse(f.departurePhase.isOffTheGround)
        XCTAssertTrue(f.isDepartingUnconfirmed)
        XCTAssertFalse(f.statusText.contains("In Air"))
    }

    func testAConfirmedTakeoffIsStatedPlainly() {
        let f = flight(minutesPastGate: 45)
        f.actualDeparture = .now.addingTimeInterval(-20 * 60)
        XCTAssertEqual(f.departurePhase, .airborne)
        XCTAssertEqual(f.statusText, "In Air")
        XCTAssertTrue(f.isDepartureConfirmed)
        XCTAssertFalse(f.isDepartingUnconfirmed)
        XCTAssertTrue(f.departurePhase.isOffTheGround)
        XCTAssertEqual(f.bannerColor, ArcTheme.onTime)
    }

    /// An unconfirmed departure must never claim a past tense, whether it is
    /// still taxiing or only past expected wheels-up.
    func testDepartureRelTextNeverClaimsDepartedWithoutConfirmation() {
        let taxiing = flight(minutesPastGate: 12)
        taxiing.recordGroundSample(onGround: true, velocity: 8, altitude: 0)
        XCTAssertTrue(taxiing.departureRelText.contains("past schedule"))
        let presumed = flight(minutesPastGate: 45)
        XCTAssertTrue(presumed.departureRelText.contains("past schedule"))
        let confirmed = flight(minutesPastGate: 45)
        confirmed.actualDeparture = .now.addingTimeInterval(-20 * 60)
        XCTAssertTrue(confirmed.departureRelText.contains("Departed"))
    }
}

/// Lock card chrome follows the same witness rule: a staleDate re-render at
/// expected wheels-up must not promote airborne layout.
final class LiveActivityDepartureLayoutTests: XCTestCase {

    private let offBlock = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { offBlock.addingTimeInterval(minutes * 60) }

    private func state(actualDeparture: Date? = nil,
                       groundState: String? = nil,
                       groundObservedAt: Date? = nil,
                       taxiStartedAt: Date? = nil) -> FlightActivityAttributes.ContentState {
        var s = FlightActivityAttributes.ContentState(
            status: "active",
            departureTime: offBlock,
            arrivalTime: offBlock.addingTimeInterval(5 * 3600),
            boardingTime: nil,
            delayMinutes: 0,
            departureGate: "B7",
            departureTerminal: "2",
            arrivalGate: nil,
            arrivalTerminal: nil,
            baggageClaim: nil,
            progress: 0)
        s.offBlock = offBlock
        s.taxiPriorMinutes = 20
        s.actualDeparture = actualDeparture
        s.groundState = groundState
        s.groundObservedAt = groundObservedAt
        s.taxiStartedAt = taxiStartedAt
        return s
    }

    func testBeforeOffBlockIsNotAirborneChrome() {
        XCTAssertFalse(state().usesAirborneLayout(at: at(-5)))
        XCTAssertEqual(state().departurePhase(at: at(-5)), .beforeDeparture)
    }

    func testPastGateNoRollKeepsGroundLayout() {
        let s = state()
        XCTAssertEqual(s.departurePhase(at: at(5)), .departing)
        XCTAssertFalse(s.usesAirborneLayout(at: at(5)))
    }

    func testTaxiingKeepsGroundLayout() {
        let s = state(groundState: "taxiing", groundObservedAt: at(10), taxiStartedAt: at(2))
        XCTAssertEqual(s.departurePhase(at: at(12)), .taxiing(since: at(2)))
        XCTAssertFalse(s.usesAirborneLayout(at: at(12)))
    }

    func testPastWheelsUpWithoutWitnessKeepsGroundLayout() {
        let s = state()
        XCTAssertEqual(s.departurePhase(at: at(21)), .presumedAirborne)
        XCTAssertFalse(s.usesAirborneLayout(at: at(21)),
                       "staleDate re-render at expected wheels-up must not flip to airborne chrome")
        // Hours later, still no witness (the radio is off): still ground.
        XCTAssertFalse(s.usesAirborneLayout(at: at(180)))
        XCTAssertEqual(s.departurePhase(at: at(180)), .presumedAirborne)
    }

    func testActualDeparturePromotesAirborneChrome() {
        let s = state(actualDeparture: at(24))
        XCTAssertEqual(s.departurePhase(at: at(25)), .airborne)
        XCTAssertTrue(s.usesAirborneLayout(at: at(25)))
    }

    func testFreshAirborneSamplePromotesAirborneChrome() {
        let s = state(groundState: "airborne", groundObservedAt: at(23))
        XCTAssertEqual(s.departurePhase(at: at(24)), .airborne)
        XCTAssertTrue(s.usesAirborneLayout(at: at(24)))
    }
}
