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

    // MARK: - Departure outlook (weather × inbound aircraft)

    /// A 25-minute knock-on with clear skies must still surface — the inbound
    /// aircraft is the #1 cause of delays and the whole point of the outlook.
    func testKnockOnAloneIsModerate() {
        let a = DelayRisk.departureOutlook(weather: nil, knockOnMinutes: 25,
                                           inboundOrigin: nil, inboundOriginIATA: nil)
        XCTAssertEqual(a.level, .moderate)
        XCTAssertTrue(a.isWorthShowing)
        XCTAssertTrue(a.reasons[0].contains("25 min"))
    }

    func testKnockOnThresholds() {
        func lvl(_ m: Int) -> DelayRisk.Level {
            DelayRisk.departureOutlook(weather: nil, knockOnMinutes: m,
                                       inboundOrigin: nil, inboundOriginIATA: nil).level
        }
        XCTAssertEqual(lvl(0), .none)
        XCTAssertEqual(lvl(12), .low)      // real but small — stays off the card
        XCTAssertEqual(lvl(20), .moderate)
        XCTAssertEqual(lvl(50), .high)
    }

    /// Fog at the field outranks a small knock-on: weather keeps top billing
    /// and the level stays high.
    func testWeatherKeepsTopBillingWhenWorse() {
        let fog = DelayRisk.assess(c(vis: 600, wx: "FG"))
        let a = DelayRisk.departureOutlook(weather: fog, knockOnMinutes: 12,
                                           inboundOrigin: nil, inboundOriginIATA: nil)
        XCTAssertEqual(a.level, .high)
        XCTAssertTrue(a.reasons[0].contains("visibility") || a.reasons[0].contains("600m"))
        XCTAssertTrue(a.reasons.contains { $0.contains("12 min") })
    }

    /// Thunderstorms where the aircraft is still parked reach us one level
    /// down: the feeder is delayed, not (yet) this flight.
    func testInboundOriginWeatherIsDemotedOneLevel() {
        let stormThere = DelayRisk.assess(c(wx: "TSRA"))
        XCTAssertEqual(stormThere.level, .high)
        let a = DelayRisk.departureOutlook(weather: nil, knockOnMinutes: 0,
                                           inboundOrigin: stormThere, inboundOriginIATA: "MUC")
        XCTAssertEqual(a.level, .moderate)
        XCTAssertTrue(a.reasons[0].contains("MUC"))
    }

    /// Merely-breezy weather at the feeder airport demotes to nothing and is
    /// dropped — restraint is the feature.
    func testMildInboundOriginWeatherIsDropped() {
        let breezy = DelayRisk.assess(c(gust: 27))
        XCTAssertEqual(breezy.level, .low)
        let a = DelayRisk.departureOutlook(weather: nil, knockOnMinutes: 0,
                                           inboundOrigin: breezy, inboundOriginIATA: "MUC")
        XCTAssertEqual(a.level, .none)
        XCTAssertTrue(a.reasons.isEmpty)
        XCTAssertFalse(a.isWorthShowing)
    }

    func testQuietDayStaysQuiet() {
        let a = DelayRisk.departureOutlook(weather: DelayRisk.assess(c(vis: 9999)),
                                           knockOnMinutes: 0,
                                           inboundOrigin: nil, inboundOriginIATA: nil)
        XCTAssertEqual(a.level, .none)
        XCTAssertFalse(a.isWorthShowing)
    }
}
