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
        XCTAssertEqual(layout.panelOpeningTop(headerHeight: 200), 874 * 0.42, accuracy: 0.001)
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

    /// With no trips, iOS 26.1 hides the accessory: the empty-state card sits
    /// on the tab bar instead of floating 56 pt above an empty slot.
    func testListReservesTheAccessoryOnlyWhileItShows() {
        let empty = MyTripsLayout(size: CGSize(width: 402, height: 874), safeTop: 62, tabBarClearance: 83,
                                  listClearsAccessory: false)
        XCTAssertEqual(empty.listBottom, 874 - 83 - 8)
        XCTAssertEqual(empty.listBottom, layout.listBottom + MyTripsLayout.accessoryHeight)
        XCTAssertEqual(empty.panelBottom, layout.panelBottom)
    }

    func testGroundViewsOnlyEverLowerThePanel() {
        XCTAssertEqual(layout.panelTopForGroundView(current: 200, headerHeight: 200),
                       layout.panelOpeningTop(headerHeight: 200))
        XCTAssertEqual(layout.panelTopForGroundView(current: 500, headerHeight: 200), 500)
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

    /// A zero-size layout has no fractions to give; it falls back to the
    /// framing every other surface already assumes rather than dividing by zero.
    func testDegenerateSizeBandIsUpperHalf() {
        XCTAssertEqual(MyTripsLayout(size: .zero, safeTop: 0, tabBarClearance: 0).band(coverTop: 0), .upperHalf)
    }

    /// On a screen too short for the whole top row and Show Less row, the
    /// list area holds at zero height instead of going negative.
    func testListBottomNeverClimbsAboveTheUnfoldedTop() {
        let tiny = MyTripsLayout(size: CGSize(width: 300, height: 300), safeTop: 59, tabBarClearance: 83)
        XCTAssertEqual(tiny.listBottom, tiny.unfoldedListTop)
    }

    /// The single test that stands in for eyeballing the layout on every
    /// device: the no-overlap rules from every test above, swept across
    /// screen sizes, accessory-hides modes, header heights and drag
    /// positions Arc actually has to support.
    func testLayoutInvariantsHoldOnEveryScreenAndHeader() {
        let screens: [(size: CGSize, safeTop: CGFloat, clearance: CGFloat)] = [
            (CGSize(width: 375, height: 667), 20, 49),
            (CGSize(width: 375, height: 812), 50, 83),
            (CGSize(width: 402, height: 874), 62, 83),
            (CGSize(width: 440, height: 956), 62, 83),
        ]

        for screen in screens {
            for hidesForDetail in [true, false] {
                let layout = MyTripsLayout(size: screen.size, safeTop: screen.safeTop,
                                           tabBarClearance: screen.clearance,
                                           accessoryHidesForDetail: hidesForDetail)
                let tag = "size=\(screen.size) hides=\(hidesForDetail)"

                for h in stride(from: 150.0, through: 500.0, by: 10.0) {
                    let highest = layout.panelHighestTop
                    let lowest = layout.panelLowestTop(headerHeight: h)
                    let opening = layout.panelOpeningTop(headerHeight: h)
                    XCTAssertLessThanOrEqual(highest, opening, "\(tag) h=\(h)")
                    XCTAssertLessThanOrEqual(opening, lowest, "\(tag) h=\(h)")

                    for current in stride(from: highest, through: layout.panelBottom, by: 7.0) {
                        let groundTop = layout.panelTopForGroundView(current: current, headerHeight: h)
                        XCTAssertGreaterThanOrEqual(groundTop, highest - 1e-9, "\(tag) h=\(h) current=\(current)")
                        XCTAssertLessThanOrEqual(groundTop, lowest + 1e-9, "\(tag) h=\(h) current=\(current)")
                        let clampedCurrent = layout.clampPanelTop(current, headerHeight: h)
                        XCTAssertGreaterThanOrEqual(groundTop, clampedCurrent - 1e-9,
                                                    "\(tag) h=\(h) current=\(current)")
                    }
                }

                for current in stride(from: layout.panelHighestTop, through: layout.panelBottom, by: 7.0) {
                    if let y = layout.recenterYAbovePanel(panelTop: current) {
                        XCTAssertGreaterThanOrEqual(y, layout.topBarBottom + MyTripsLayout.gap - 1e-9,
                                                    "\(tag) current=\(current)")
                    }
                }

                for h in stride(from: 0.0, through: 1500.0, by: 25.0) {
                    let y = layout.pillRowY(listTop: layout.listTop(folded: true, foldedHeight: h))
                    XCTAssertGreaterThanOrEqual(y, layout.topBarBottom + MyTripsLayout.gap - 1e-9,
                                                "\(tag) foldedHeight=\(h)")
                }

                for coverTop in stride(from: 0.0, through: Double(screen.size.height), by: 25.0) {
                    let band = layout.band(coverTop: CGFloat(coverTop))
                    XCTAssertGreaterThanOrEqual(band.top, 0, "\(tag) coverTop=\(coverTop)")
                    XCTAssertLessThan(band.top, band.bottom, "\(tag) coverTop=\(coverTop)")
                    XCTAssertLessThanOrEqual(band.bottom, 1, "\(tag) coverTop=\(coverTop)")
                }
            }
        }
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

    /// With the share button hidden, only the "..." capsule bounds the pill,
    /// starting further right (x 336 instead of x 294).
    func testNeverOverlapsWhenShareIsHidden() {
        let maxWidth = TopPillPlacement.maxWidth(leadingEdge: 60, trailingEdge: 336)
        XCTAssertEqual(maxWidth, 260)
        for w in stride(from: 40.0, through: Double(maxWidth), by: 1) {
            let x = TopPillPlacement.centreX(pillWidth: w, width: 402, leadingEdge: 60, trailingEdge: 336)
            XCTAssertGreaterThanOrEqual(x - w / 2, 68 - 1e-9, "w=\(w)")
            XCTAssertLessThanOrEqual(x + w / 2, 328 + 1e-9, "w=\(w)")
        }
    }

    /// The same rule on a narrower, 375 pt screen.
    func testNeverOverlapsOnA375PointScreen() {
        let maxWidth = TopPillPlacement.maxWidth(leadingEdge: 60, trailingEdge: 267)
        XCTAssertEqual(maxWidth, 191)
        for w in stride(from: 40.0, through: Double(maxWidth), by: 1) {
            let x = TopPillPlacement.centreX(pillWidth: w, width: 375, leadingEdge: 60, trailingEdge: 267)
            XCTAssertGreaterThanOrEqual(x - w / 2, 68 - 1e-9, "w=\(w)")
            XCTAssertLessThanOrEqual(x + w / 2, 259 + 1e-9, "w=\(w)")
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

    /// 224.99 m/s rounds to 810 km/h rather than truncating to 809.
    func testRoundsRatherThanTruncates() {
        XCTAssertEqual(LiveReadout.text(speed: 224.99, altitude: nil, updatedAt: now, now: now), "810 km/h")
    }

    /// A non-finite or negative part is dropped on its own; it doesn't sink
    /// the whole readout.
    func testNonFiniteAndNegativePartsAreDroppedNotFatal() {
        XCTAssertEqual(LiveReadout.text(speed: .nan, altitude: 900, updatedAt: now, now: now), "900 m")
        XCTAssertNil(LiveReadout.text(speed: -1, altitude: nil, updatedAt: now, now: now))
    }

    /// Speed uses the same grouped formatting as altitude.
    func testSpeedIsGroupedLikeAltitude() {
        XCTAssertEqual(LiveReadout.text(speed: 310, altitude: nil, updatedAt: now, now: now), "1'116 km/h")
    }

    func testFutureTimestampBeyondToleranceIsNotFresh() {
        XCTAssertNil(LiveReadout.text(speed: 225, altitude: 11280, updatedAt: now.addingTimeInterval(120), now: now))
    }
}
