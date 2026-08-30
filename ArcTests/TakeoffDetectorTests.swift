import XCTest
@testable import Arc

/// The device witness's judgement, exercised sample by sample. The service
/// around it is CoreLocation/CoreMotion plumbing; THIS is where a false "In
/// Air" or a missed takeoff would come from.
final class TakeoffDetectorTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: - The speed path

    func testTwoFastFixesAreATakeoffRoll() {
        var d = TakeoffDetector()
        XCTAssertEqual(d.speed(45, at: at(0)), .none, "one fix could be GPS noise")
        XCTAssertEqual(d.speed(46, at: at(1)), .tookOff)
        XCTAssertTrue(d.airborne)
    }

    func testHighwaySpeedsNeverTrigger() {
        var d = TakeoffDetector()
        for i in 0..<600 {   // ten minutes at 140 km/h
            XCTAssertEqual(d.speed(39, at: at(Double(i))), .none)
        }
    }

    func testASingleSpikeBetweenSlowFixesIsNoise() {
        var d = TakeoffDetector()
        _ = d.speed(10, at: at(0))
        XCTAssertEqual(d.speed(50, at: at(1)), .none)
        XCTAssertEqual(d.speed(9, at: at(2)), .none)
        XCTAssertEqual(d.speed(50, at: at(3)), .none, "the counter must reset on a slow fix")
    }

    func testNegativeSpeedMeansNoEstimateAndIsIgnored() {
        var d = TakeoffDetector()
        _ = d.speed(45, at: at(0))
        XCTAssertEqual(d.speed(-1, at: at(1)), .none)
        XCTAssertEqual(d.speed(45, at: at(2)), .tookOff,
                       "a missing estimate must not reset a roll in progress")
    }

    // MARK: - The climb path (the airplane-mode path)

    /// A pressurised cabin climbs ~1.5–2.5 m/s of pressure altitude for
    /// minutes after rotation. 150 m in 80 s clears both gates.
    func testASustainedCabinClimbIsATakeoff() {
        var d = TakeoffDetector()
        var verdict = TakeoffDetector.Verdict.none
        for i in 0...80 {
            verdict = d.altitude(Double(i) * 2, at: at(Double(i)))
            if verdict != .none { break }
        }
        XCTAssertEqual(verdict, .tookOff)
    }

    /// A slow drive up a mountain gains plenty of altitude at nothing like
    /// the rate — 120 m over ten minutes must stay quiet.
    func testASlowHillClimbNeverTriggers() {
        var d = TakeoffDetector()
        for i in 0...600 {
            XCTAssertEqual(d.altitude(Double(i) * 0.2, at: at(Double(i))), .none)
        }
    }

    /// Baseline is the LOWEST seen: a session that starts with the altimeter
    /// drifting downward must not count the recovery as climb.
    func testDownwardDriftDoesNotInflateTheClimb() {
        var d = TakeoffDetector()
        _ = d.altitude(0, at: at(0))
        _ = d.altitude(-40, at: at(30))
        // Back to +90 relative to session start = 130 above baseline, but
        // only after a long crawl: the rate gate holds it.
        for i in 0...600 {
            let alt = -40 + Double(i) * 0.22
            XCTAssertEqual(d.altitude(alt, at: at(60 + Double(i))), .none)
        }
    }

    /// Pressure wobble below the anchor threshold resets the rate anchor —
    /// weather noise around ±20 m is not the start of a climb.
    func testGroundPressureWobbleStaysQuiet() {
        var d = TakeoffDetector()
        for i in 0...200 {
            let alt = 20 * sin(Double(i) / 10)
            XCTAssertEqual(d.altitude(alt, at: at(Double(i) * 3)), .none)
        }
    }

    // MARK: - The landing watch

    private func airborneDetector() -> TakeoffDetector {
        var d = TakeoffDetector()
        d.noteAirborne()
        return d
    }

    func testDescentThenQuietIsALanding() {
        var d = airborneDetector()
        _ = d.altitude(1800, at: at(0))                       // cruise cabin altitude
        for i in 0...300 {                                    // descent: 1800 → 300
            _ = d.altitude(1800 - Double(i) * 5, at: at(Double(i) * 2))
        }
        // On the ground: pressure holds still. Quiet must run its full clock.
        var verdict = TakeoffDetector.Verdict.none
        for i in 0...60 {
            verdict = d.altitude(300, at: at(700 + Double(i) * 10))
            if verdict == .landed { break }
        }
        XCTAssertEqual(verdict, .landed)
    }

    func testCruiseIsNotALanding() {
        var d = airborneDetector()
        _ = d.altitude(1800, at: at(0))
        // Hours of level cruise: quiet, but no descent has happened.
        for i in 0...720 {
            XCTAssertEqual(d.altitude(1800 + 3 * sin(Double(i) / 7), at: at(Double(i) * 10)), .none)
        }
    }

    func testAStepDownInCruiseIsNotALanding() {
        var d = airborneDetector()
        _ = d.altitude(1800, at: at(0))
        // A 100 m cabin step-down, then quiet — not the 250 m a landing gives back.
        for i in 0...20 { _ = d.altitude(1800 - Double(i) * 5, at: at(Double(i))) }
        for i in 0...60 {
            XCTAssertEqual(d.altitude(1700, at: at(100 + Double(i) * 10)), .none)
        }
    }

    /// Another witness confirming first skips the takeoff verdict but arms
    /// the landing watch.
    func testNoteAirborneArmsTheLandingWatchWithoutAVerdict() {
        var d = TakeoffDetector()
        d.noteAirborne()
        XCTAssertTrue(d.airborne)
        XCTAssertEqual(d.speed(50, at: at(0)), .none)
        XCTAssertEqual(d.speed(50, at: at(1)), .none, "no second takeoff claim")
    }
}
