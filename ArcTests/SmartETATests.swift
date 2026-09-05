import XCTest
@testable import Arc

/// Mira: provider/airline `estimatedArrival` always wins the hero.
/// Arc's remaining-time projection is a labeled prediction only when
/// that stamp is missing. We do not chase Flighty's 20:18.
@MainActor
final class SmartETATests: XCTestCase {
    /// 19:50 BCN = 17:50Z. Schedule 19:25→20:35 is 2h10m.
    private let dep = Date(timeIntervalSince1970: 1_788_371_400)      // 17:50Z
    private let scheduledDep = Date(timeIntervalSince1970: 1_788_369_900) // 17:25Z
    private let scheduledArr = Date(timeIntervalSince1970: 1_788_377_700) // 19:35Z
    private let revisedArr = Date(timeIntervalSince1970: 1_788_375_600)   // 19:00Z = 20:00 LIS
    private let now = Date(timeIntervalSince1970: 1_788_375_840)          // 19:04Z = 21:04 CEST

    private func airborneVY(estimate: Date?) -> Flight {
        let f = Flight(flightNumber: "VY8462", date: scheduledDep)
        f.departureIATA = "BCN"
        f.arrivalIATA = "LIS"
        f.scheduledDeparture = scheduledDep
        f.scheduledArrival = scheduledArr
        f.actualDeparture = dep
        f.delayMinutes = 25
        f.status = .active
        f.estimatedArrival = estimate
        f.departureLat = 41.297
        f.departureLon = 2.078
        f.arrivalLat = 38.774
        f.arrivalLon = -9.134
        // South of Setúbal — remaining great-circle is short.
        f.liveLat = 38.42
        f.liveLon = -8.90
        f.liveSpeed = 131 // 472 km/h
        f.liveUpdatedAt = now
        return f
    }

    func testProviderEstimateWinsEvenWhenAlreadyBehindTheClock() {
        let f = airborneVY(estimate: revisedArr)
        XCTAssertTrue(revisedArr < now, "the 20:00 LIS stamp is already behind the screenshot clock")
        XCTAssertEqual(f.smartETA(at: now), revisedArr)
        XCTAssertNil(f.arrivalPrediction(at: now))
        XCTAssertEqual(f.estimatedArrival, revisedArr)
    }

    func testProviderEstimateWinsWhenLiveIsLaterHolding() {
        let conservative = Date(timeIntervalSince1970: 1_788_377_100) // 19:25Z
        let f = airborneVY(estimate: conservative)
        XCTAssertEqual(f.smartETA(at: now), conservative)
        XCTAssertNil(f.arrivalPrediction(at: now))
    }

    func testNoEstimateUsesLiveProjectionAsALabeledPrediction() {
        let f = airborneVY(estimate: nil)
        let eta = f.smartETA(at: now)
        XCTAssertGreaterThan(eta, now)
        XCTAssertEqual(f.arrivalPrediction(at: now), eta)
        // Live remaining is display-only. The stored field stays empty so
        // the next refresh cannot dress Arc's guess up as an airline ETA.
        XCTAssertNil(f.estimatedArrival)
        XCTAssertNil(f.applyingLiveArrival(eta))
    }

    func testNoEstimateFallsBackToDurationFromActualDeparture() {
        let f = airborneVY(estimate: nil)
        f.liveLat = nil
        f.liveLon = nil
        f.liveSpeed = nil
        XCTAssertEqual(f.smartETA(at: now), dep.addingTimeInterval(2 * 3600 + 10 * 60))
        XCTAssertNil(f.arrivalPrediction(at: now), "duration-from-schedule is the timetable, not Arc ✦")
    }

    func testLiveProjectionNeverOverwritesAProviderEstimate() {
        let f = airborneVY(estimate: revisedArr)
        let live = f.liveProjectedArrival(at: now)
        XCTAssertNotNil(live)
        XCTAssertNil(f.applyingLiveArrival(live!))
        XCTAssertEqual(f.estimatedArrival, revisedArr)
    }
}
