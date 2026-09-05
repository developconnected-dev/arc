import XCTest
@testable import Arc

/// Bug 2a — VY8462 showed LIS 20:00 (ADB revisedTime) while still on
/// approach. Flighty's 20:18 was remaining distance + an approach buffer.
/// `smartETA` used to return `estimatedArrival` first, so a live position
/// could never correct a stale-early airline revision.
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
        // South of Setúbal, heading for LIS — remaining great-circle is
        // short; without an approach buffer this would land even earlier
        // than the airline's 20:00.
        f.liveLat = 38.42
        f.liveLon = -8.90
        f.liveSpeed = 131 // 472 km/h
        f.liveUpdatedAt = now
        return f
    }

    func testStaleEarlyEstimateYieldsToLiveProjection() {
        let f = airborneVY(estimate: revisedArr)
        XCTAssertTrue(revisedArr < now, "the 20:00 LIS stamp is already behind the screenshot clock")
        let eta = f.smartETA(at: now)
        XCTAssertGreaterThan(eta, now)
        XCTAssertGreaterThan(eta, revisedArr)
        // ~5m great-circle remaining + 15m approach buffer. Flighty's 20:18
        // is the same idea; we will not match it to the minute.
        XCTAssertEqual(eta.timeIntervalSince(now), 21 * 60, accuracy: 8 * 60)
    }

    func testFreshProviderEstimateIsKeptWhenLiveIsMoreOptimistic() {
        // Airline/ADB already at 20:25 LIS — don't invent an earlier arrival
        // from great-circle remaining.
        let conservative = Date(timeIntervalSince1970: 1_788_377_100) // 19:25Z
        let f = airborneVY(estimate: conservative)
        XCTAssertEqual(f.smartETA(at: now), conservative)
    }

    func testNoEstimateFallsBackToDurationFromActualDeparture() {
        let f = airborneVY(estimate: nil)
        f.liveLat = nil
        f.liveLon = nil
        f.liveSpeed = nil
        // 17:50Z + 2h10m = 20:00Z = 21:00 LIS, not the wall-clock 1h10m
        // (19:50+1h10m displayed in Lisbon as 20:00) that ignores the offset.
        XCTAssertEqual(f.smartETA(at: now), dep.addingTimeInterval(2 * 3600 + 10 * 60))
    }
}
