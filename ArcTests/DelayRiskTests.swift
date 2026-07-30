import XCTest
@testable import Arc

/// The point of these thresholds is restraint: the app should say nothing when
/// the weather is merely unpleasant, and speak up only when a delay is a real
/// prospect.
final class DelayRiskTests: XCTestCase {
    private func c(vis: Int? = nil, ceiling: Int? = nil, gust: Int? = nil,
                   shear: Bool? = nil, wx: String? = nil) -> DelayRisk.Conditions {
        .init(visibilityM: vis, ceilingFt: ceiling, windKt: nil,
              gustKt: gust, windShear: shear, wx: wx)
    }

    func testGoodWeatherSaysNothing() {
        let a = DelayRisk.assess(c(vis: 9999, ceiling: 3000, gust: 12))
        XCTAssertEqual(a.level, .none)
        XCTAssertFalse(a.isWorthShowing)
    }

    /// Light rain is not a delay. This is the case the user explicitly didn't
    /// want cluttering the app.
    func testDrizzleIsNotWorthShowing() {
        let a = DelayRisk.assess(c(vis: 8000, ceiling: 2500, wx: "-RA"))
        XCTAssertEqual(a.level, .none)
        XCTAssertFalse(a.isWorthShowing)
    }

    func testFogIsHigh() {
        let a = DelayRisk.assess(c(vis: 700, wx: "FG"))
        XCTAssertEqual(a.level, .high)
        XCTAssertTrue(a.reasons.contains { $0.contains("700m") })
    }

    func testMarginalVisibilityIsModerate() {
        XCTAssertEqual(DelayRisk.assess(c(vis: 3000)).level, .moderate)
    }

    func testLowCeilingIsHigh() {
        XCTAssertEqual(DelayRisk.assess(c(ceiling: 300)).level, .high)
        XCTAssertEqual(DelayRisk.assess(c(ceiling: 800)).level, .moderate)
    }

    /// Breezy is noted but stays below the reporting bar; real gusts don't.
    func testGustLadder() {
        XCTAssertEqual(DelayRisk.assess(c(gust: 27)).level, .low)
        XCTAssertFalse(DelayRisk.assess(c(gust: 27)).isWorthShowing)
        XCTAssertEqual(DelayRisk.assess(c(gust: 38)).level, .moderate)
        XCTAssertEqual(DelayRisk.assess(c(gust: 50)).level, .high)
    }

    func testThunderstormsAndFreezingAreHigh() {
        XCTAssertEqual(DelayRisk.assess(c(wx: "TSRA")).level, .high)
        XCTAssertEqual(DelayRisk.assess(c(wx: "FZRA")).level, .high)
        XCTAssertEqual(DelayRisk.assess(c(wx: "SN")).level, .moderate)
    }

    func testWindShearIsModerate() {
        XCTAssertEqual(DelayRisk.assess(c(shear: true)).level, .moderate)
    }

    /// Clear now, fogged in by departure — the whole reason the forecast is
    /// consulted at all.
    func testForecastCanBeWorseThanNow() {
        let combined = DelayRisk.assess(now: c(vis: 9999, ceiling: 4000),
                                        atDeparture: c(vis: 600, wx: "FG"))
        XCTAssertEqual(combined.level, .high)
    }

    func testMissingDataIsNotARisk() {
        XCTAssertEqual(DelayRisk.assess(now: nil, atDeparture: nil).level, .none)
        XCTAssertEqual(DelayRisk.assess(c()).level, .none)
    }

    /// Real numbers from the live endpoint: Athens forecast 32kt gusts today.
    func testRealAthensForecastReadsAsModerate() {
        let a = DelayRisk.assess(c(vis: 9656, gust: 32))
        XCTAssertEqual(a.level, .low, "32kt is breezy, not a delay")
        XCTAssertFalse(a.isWorthShowing)
    }
}
