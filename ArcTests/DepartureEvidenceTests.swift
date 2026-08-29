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
        XCTAssertEqual(evidence().phase(at: at(-5)), .beforeDeparture)
    }

    func testInsideTheTaxiWindowItIsDepartingNotAirborne() {
        let e = evidence()
        XCTAssertEqual(e.phase(at: at(1)), .departing)
        XCTAssertEqual(e.phase(at: at(19)), .departing)
    }

    /// Past the expected wheels-up with nobody confirming anything, Arc
    /// commits — but only to a presumption, never to a green fact.
    func testPastExpectedWheelsUpItIsPresumedNotConfirmed() {
        XCTAssertEqual(evidence().phase(at: at(21)), .presumedAirborne)
    }

    // MARK: - The early pushback: seen rolling BEFORE off-block

    /// Regression: the phase asked "before off-block?" before consulting a
    /// fresh sighting — and off-block is the schedule plus the FILED delay,
    /// so a pushback any earlier than the airline's (routinely overstated)
    /// delay put the entire real taxi "before departure". Every surface
    /// held its countdown through the roll and jumped straight to In Air at
    /// wheels-up; Taxiing never showed.
    func testSeenRollingBeforeOffBlockIsTaxiing() {
        let e = evidence(groundState: "taxiing",
                         groundObservedAt: at(-4), taxiStartedAt: at(-4))
        XCTAssertEqual(e.phase(at: at(-3)), .taxiing(since: at(-4)))
    }

    /// A hold in the queue before the printed departure minute is still the
    /// taxi — the same no-flicker rule as after it.
    func testAPauseBeforeOffBlockIsStillTaxiing() {
        let e = evidence(groundState: "at_gate",
                         groundObservedAt: at(-2), taxiStartedAt: at(-6))
        XCTAssertEqual(e.phase(at: at(-1)), .taxiing(since: at(-6)))
    }

    /// Parked at the gate before the gate time is exactly what the timetable
    /// expects — a fresh at-gate sighting must NOT read as departing early.
    func testAtGateBeforeOffBlockIsStillBeforeDeparture() {
        let e = evidence(groundState: "at_gate", groundObservedAt: at(-5))
        XCTAssertEqual(e.phase(at: at(-4)), .beforeDeparture)
    }

    // MARK: - The incident: a long taxi at a busy airport

    /// The airport's learned taxi-out is what the hedge is measured against.
    /// At a hub that taxis 35 minutes, minute 25 is still on the ground.
    func testALearnedTaxiPriorHoldsTheHedgeOpenLongerAtASlowAirport() {
        let slow = evidence(taxiPriorMinutes: 35)
        XCTAssertEqual(slow.phase(at: at(25)), .departing)
        XCTAssertEqual(slow.phase(at: at(36)), .presumedAirborne)
    }

    /// A witness that saw the aircraft rolling outranks any clock arithmetic:
    /// still taxiing at minute 40 is still not airborne.
    func testFreshTaxiingObservationBeatsTheClock() {
        let e = evidence(groundState: "taxiing", groundObservedAt: at(38), taxiStartedAt: at(6))
        XCTAssertEqual(e.phase(at: at(40)), .taxiing(since: at(6)))
    }

    /// Still at the stand long past the timetable — the one case where
    /// "In Flight" would be most obviously wrong.
    func testFreshAtGateObservationKeepsItOnTheGroundIndefinitely() {
        let e = evidence(groundState: "at_gate", groundObservedAt: at(52))
        XCTAssertEqual(e.phase(at: at(55)), .departing)
    }

    /// Most of a long taxi is spent stopped in the queue for the runway.
    /// Having started to roll, a stationary sample is still the taxi.
    func testAPauseInTheQueueIsStillTaxiing() {
        let e = evidence(groundState: "at_gate", groundObservedAt: at(20), taxiStartedAt: at(6))
        XCTAssertEqual(e.phase(at: at(21)), .taxiing(since: at(6)))
    }

    /// Adopted from PR #4's one clean idea: a sample rotting mid-taxi must
    /// not flick the card back to "Departing" — the started taxi holds until
    /// the slid expected wheels-up (about one taxi-time after the last
    /// sighting), then hands over to the presumption exactly as before.
    func testARottedSampleMidTaxiIsStillTheTaxi() {
        let e = evidence(groundState: "taxiing", groundObservedAt: at(10),
                         taxiStartedAt: at(6), lastSeenOnGround: at(10))
        // 18 minutes after the last sighting: rotted, but wheels-up slid to
        // minute 30, so the taxi holds…
        XCTAssertEqual(e.phase(at: at(28)), .taxiing(since: at(6)))
        // …and past the slid wheels-up the presumption takes over.
        XCTAssertEqual(e.phase(at: at(31)), .presumedAirborne)
    }

    /// Evidence rots. An hour-old sighting says nothing about now, so the
    /// clock takes over again rather than pinning the flight to the gate.
    func testStaleGroundObservationStopsCounting() {
        let e = evidence(groundState: "taxiing", groundObservedAt: at(10), taxiStartedAt: at(6))
        XCTAssertEqual(e.phase(at: at(80)), .presumedAirborne)
    }

    // MARK: - Confirmation ends every hedge

    func testAReportedDepartureIsAirborne() {
        let e = evidence(actualDeparture: at(24))
        XCTAssertEqual(e.phase(at: at(25)), .airborne)
    }

    func testAnAirborneSightingIsAirborne() {
        let e = evidence(groundState: "airborne", groundObservedAt: at(23))
        XCTAssertEqual(e.phase(at: at(24)), .airborne)
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
    }

    /// A stream of "still nothing" refreshes must not push the commitment
    /// out for ever; after the cap Arc presumes rather than hedges.
    func testTheSlidingHedgeIsCapped() {
        let e = evidence(lastSeenOnGround: at(200))
        XCTAssertEqual(e.expectedWheelsUp, offBlock.addingTimeInterval(DepartureEvidence.hardCap))
        XCTAssertEqual(e.phase(at: at(95)), .presumedAirborne)
    }

    // MARK: - What the surfaces ask

    func testHedgingIsExactlyTheUnconfirmedStates() {
        XCTAssertTrue(evidence().phase(at: at(5)).isHedged)
        XCTAssertTrue(evidence(groundState: "taxiing", groundObservedAt: at(5)).phase(at: at(6)).isHedged)
        XCTAssertTrue(evidence().phase(at: at(60)).isHedged)
        XCTAssertFalse(evidence(actualDeparture: at(24)).phase(at: at(25)).isHedged)
        XCTAssertFalse(evidence().phase(at: at(-5)).isHedged)
    }

    func testOffTheGroundCoversPresumedAndConfirmedOnly() {
        XCTAssertFalse(evidence().phase(at: at(5)).isOffTheGround)
        XCTAssertFalse(evidence(groundState: "taxiing", groundObservedAt: at(5)).phase(at: at(6)).isOffTheGround)
        XCTAssertTrue(evidence().phase(at: at(60)).isOffTheGround)
        XCTAssertTrue(evidence(actualDeparture: at(24)).phase(at: at(25)).isOffTheGround)
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
        XCTAssertEqual(f.statusText, "Departing")
        XCTAssertEqual(f.bannerHeadline, "Departing")
        XCTAssertTrue(f.isDepartingUnconfirmed)
        XCTAssertFalse(f.departurePhase.isOffTheGround)
    }

    func testSeenRollingSaysTaxiing() {
        let f = flight(minutesPastGate: 12)
        f.recordGroundSample(onGround: true, velocity: 8, altitude: 0)
        XCTAssertEqual(f.statusText, "Taxiing")
        XCTAssertEqual(f.bannerHeadline, "Taxiing", "no duration worth printing in the first minute")
        XCTAssertNotNil(f.taxiElapsed)
        // Once it has gone on a while, the banner carries the number a person
        // in seat 14B actually wants.
        f.taxiStartedAt = .now.addingTimeInterval(-13 * 60)
        XCTAssertEqual(f.bannerHeadline, "Taxiing · 13m")
    }

    /// Past the expected wheels-up with nobody confirming: Arc says it is
    /// flying, but as a presumption — muted, and never as a fact.
    func testPresumedAirborneIsSaidQuietly() {
        let f = flight(minutesPastGate: 45)
        XCTAssertEqual(f.departurePhase, .presumedAirborne)
        XCTAssertEqual(f.statusText, "In Air")
        XCTAssertEqual(f.bannerColor, Color(.secondaryLabel))
        XCTAssertFalse(f.isDepartureConfirmed)
    }

    func testAConfirmedTakeoffIsStatedPlainly() {
        let f = flight(minutesPastGate: 45)
        f.actualDeparture = .now.addingTimeInterval(-20 * 60)
        XCTAssertEqual(f.departurePhase, .airborne)
        XCTAssertEqual(f.statusText, "In Air")
        XCTAssertTrue(f.isDepartureConfirmed)
        XCTAssertFalse(f.isDepartingUnconfirmed)
        XCTAssertEqual(f.bannerColor, ArcTheme.onTime)
    }

    /// An unconfirmed departure must never claim a past tense, whether it is
    /// still taxiing or only presumed airborne.
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
