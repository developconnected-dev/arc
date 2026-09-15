import XCTest
@testable import Arc

/// iPhone 16 Pro in points: 402 × 874, 62 pt status/island inset, and a
/// tab bar reaching 83 pt up from the bottom edge.
final class MyTripsLayoutTests: XCTestCase {
    private let layout = MyTripsLayout(size: CGSize(width: 402, height: 874), safeTop: 62, tabBarClearance: 83)

    func testTopRowAndListBounds() {
        XCTAssertEqual(layout.topBarY, 66)
        XCTAssertEqual(layout.topBarBottom, 110)
        XCTAssertEqual(layout.unfoldedListTop, 170)
        XCTAssertEqual(layout.listBottom, 874 - 83 - MyTripsLayout.accessoryHeight - 8)
    }

    func testFoldedStackSitsOnTheBottomAndNeverClimbsPastUnfolded() {
        XCTAssertEqual(layout.listTop(folded: true, foldedHeight: 250), layout.listBottom - 250)
        XCTAssertEqual(layout.listTop(folded: true, foldedHeight: 2000), layout.unfoldedListTop)
        XCTAssertEqual(layout.listTop(folded: false, foldedHeight: 250), layout.unfoldedListTop)
    }

    /// The Show More / recenter row never reaches into the top row,
    /// whatever the folded block measures.
    func testPillRowNeverOverlapsTheTopRow() {
        for h in stride(from: 0.0, through: 2000.0, by: 25.0) {
            for folded in [true, false] {
                let y = layout.pillRowY(listTop: layout.listTop(folded: folded, foldedHeight: h))
                XCTAssertGreaterThanOrEqual(y, layout.topBarBottom + MyTripsLayout.gap, "h=\(h) folded=\(folded)")
            }
        }
    }

    func testPanelOpensAt58PercentAndClampsBetweenTopRowAndHeader() {
        XCTAssertEqual(layout.panelOpeningTop, 874 * 0.42, accuracy: 0.001)
        XCTAssertEqual(layout.panelHighestTop, 118)
        XCTAssertEqual(layout.panelBottom, 874 - 83 - 8)
        let lowest = layout.panelBottom - MyTripsLayout.panelStrip - Morph.detailTopInset - 200
        XCTAssertEqual(layout.clampPanelTop(20, headerHeight: 200), 118)
        XCTAssertEqual(layout.clampPanelTop(900, headerHeight: 200), lowest)
        XCTAssertEqual(layout.clampPanelTop(400, headerHeight: 200), 400)
    }

    /// iOS 26.0 cannot switch the accessory off, so a detail clears it there.
    func testPanelClearsTheAccessoryWhenItCannotHide() {
        let old = MyTripsLayout(size: CGSize(width: 402, height: 874), safeTop: 62, tabBarClearance: 83,
                                accessoryHidesForDetail: false)
        XCTAssertEqual(old.panelBottom, old.listBottom)
    }

    func testGroundViewsOnlyEverLowerThePanel() {
        XCTAssertEqual(layout.panelTopForGroundView(current: 200), layout.panelOpeningTop)
        XCTAssertEqual(layout.panelTopForGroundView(current: 500), 500)
    }

    func testRecenterRidesAbovePanelUntilItWouldCrowdTheTopRow() {
        XCTAssertEqual(layout.recenterYAbovePanel(panelTop: 400), 400 - 8 - 44)
        XCTAssertNil(layout.recenterYAbovePanel(panelTop: layout.panelHighestTop))
        for top in stride(from: layout.panelHighestTop, through: 800, by: 1) {
            if let y = layout.recenterYAbovePanel(panelTop: top) {
                XCTAssertGreaterThanOrEqual(y, layout.topBarBottom + MyTripsLayout.gap)
            }
        }
    }

    func testBandIsTheMapBetweenTopRowAndCover() {
        let band = layout.band(coverTop: 437)
        XCTAssertEqual(band.top, 110.0 / 874, accuracy: 1e-9)
        XCTAssertEqual(band.bottom, 437.0 / 874, accuracy: 1e-9)
    }
}

/// The centre pill keeps 8 pt from the avatar (ends at x 60) and the
/// share/"..." capsule (starts at x 294) on a 402 pt screen.
final class TopPillPlacementTests: XCTestCase {
    func testTitleThatFitsStaysOnTheScreenCentre() {
        XCTAssertEqual(TopPillPlacement.centreX(pillWidth: 100, width: 402, leadingEdge: 60, trailingEdge: 294), 201)
    }

    func testWideReadoutSlidesAwayFromTheButtons() {
        let x = TopPillPlacement.centreX(pillWidth: 190, width: 402, leadingEdge: 60, trailingEdge: 294)
        XCTAssertEqual(x + 95, 294 - 8)
        XCTAssertGreaterThanOrEqual(x - 95, 60 + 8)
    }

    func testNeverOverlapsForAnyWidthThatFits() {
        let maxWidth = TopPillPlacement.maxWidth(leadingEdge: 60, trailingEdge: 294)
        XCTAssertEqual(maxWidth, 218)
        for w in stride(from: 40.0, through: Double(maxWidth), by: 1) {
            let x = TopPillPlacement.centreX(pillWidth: w, width: 402, leadingEdge: 60, trailingEdge: 294)
            XCTAssertGreaterThanOrEqual(x - w / 2, 68 - 1e-9, "w=\(w)")
            XCTAssertLessThanOrEqual(x + w / 2, 286 + 1e-9, "w=\(w)")
        }
    }
}

final class LiveReadoutTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSpeedAndAltitudeInTheAppsUnits() {
        let text = LiveReadout.text(speed: 225, altitude: 11280, updatedAt: now.addingTimeInterval(-60), now: now)
        XCTAssertEqual(text, "810 km/h · 11'280 m")
    }

    func testStalePositionSaysNothing() {
        XCTAssertNil(LiveReadout.text(speed: 225, altitude: 11280, updatedAt: now.addingTimeInterval(-16 * 60), now: now))
        XCTAssertNil(LiveReadout.text(speed: 225, altitude: 11280, updatedAt: nil, now: now))
    }

    func testOneValueIsEnoughAndNoneIsNothing() {
        XCTAssertEqual(LiveReadout.text(speed: nil, altitude: 900, updatedAt: now, now: now), "900 m")
        XCTAssertNil(LiveReadout.text(speed: nil, altitude: nil, updatedAt: now, now: now))
    }
}
