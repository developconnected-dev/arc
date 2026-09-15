import XCTest

@MainActor
final class FloatingTripsTests: XCTestCase {
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-seedDemo", "-uiNoPrompt", "-apiEndpoint", "http://127.0.0.1:9"] + extra
        app.launch()
        return app
    }

    /// Polls instead of sleeping a fixed amount: swipes and fold toggles
    /// animate on a spring (~0.35-0.45s), and the exact settle time isn't
    /// worth pinning down in a test.
    @discardableResult
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return condition() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return true
    }

    private func visibleTripRows(_ app: XCUIApplication) -> [String] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "trip-row-"))
            .allElementsBoundByIndex.filter { $0.isHittable }.map(\.identifier)
    }

    /// The stack's accessibility value, "Journey 2 of 6, Zurich to Rome" (its
    /// label is the constant "Journeys").
    private func stackValue(_ stack: XCUIElement) -> String {
        stack.value as? String ?? ""
    }

    /// Parses "Journey 2 of 6, Zurich to Rome" into (2, 6).
    private func pageAndCount(_ label: String) -> (page: Int, count: Int)? {
        guard let journeyRange = label.range(of: "Journey ") else { return nil }
        let rest = label[journeyRange.upperBound...]
        guard let ofRange = rest.range(of: " of ") else { return nil }
        let pageString = rest[rest.startIndex..<ofRange.lowerBound]
        let afterOf = rest[ofRange.upperBound...]
        let countString = afterOf.prefix { $0.isNumber }
        guard let page = Int(pageString), let count = Int(countString) else { return nil }
        return (page, count)
    }

    func testFoldedShowsOnlyTheNextJourneyAndUnfoldsAndFoldsBack() {
        let app = launch()
        let next = app.buttons["trip-row-LX14"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        let foldedRows = visibleTripRows(app)
        XCTAssertEqual(foldedRows.count, 1, "a folded stack shows only the current journey")

        let toggle = app.buttons["trips-fold-toggle"]
        XCTAssertEqual(toggle.label, "Show More")
        toggle.tap()
        XCTAssertTrue(waitUntil { visibleTripRows(app).count > foldedRows.count })
        XCTAssertEqual(toggle.label, "Show Less")
        XCTAssertGreaterThan(visibleTripRows(app).count, 1)

        toggle.tap()
        XCTAssertTrue(waitUntil { visibleTripRows(app).count == 1 })
        XCTAssertTrue(next.isHittable)
    }

    /// The + bubble beside the tab bar opens Add a trip, and leaves the
    /// selection on the tab the user was already on.
    func testThePlusBubbleOpensAddAndKeepsTheCurrentTab() {
        let app = launch()
        XCTAssertTrue(app.buttons["trip-row-LX14"].waitForExistence(timeout: 5))

        let bubble = app.buttons["Add a trip"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 3))
        bubble.tap()
        XCTAssertTrue(app.staticTexts["Add Trip"].waitForExistence(timeout: 5),
                      "the + bubble should present the Add screen")

        // Still My Trips underneath: the selection never moved to the bubble.
        XCTAssertTrue(app.buttons["My Trips"].isSelected)
    }

    func testTopRowTitleIsMyTripsOnTheList() {
        let app = launch()
        let title = app.descendants(matching: .any)["map-top-title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["My Trips"].exists)
    }

    func testOpeningFromTheFoldedStackHidesItsChromeAndClosingRestoresIt() {
        let app = launch()
        let row = app.buttons["trip-row-LX14"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["trip-detail-ready"].firstMatch.waitForExistence(timeout: 3))
        // Hidden from accessibility while the panel is up, so it doesn't exist at all.
        XCTAssertFalse(app.buttons["trips-fold-toggle"].exists)

        app.buttons["trip-detail-close"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["trips-fold-toggle"].isHittable)
        XCTAssertEqual(app.buttons["trips-fold-toggle"].label, "Show More")
    }

    /// Dragging resizes; it never closes. Only the X closes.
    func testDraggingThePanelNeverClosesIt() {
        let app = launch()
        app.buttons["trip-row-LX14"].tap()
        let ready = app.descendants(matching: .any)["trip-detail-ready"].firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 3))
        let strip = app.descendants(matching: .any)["trip-panel-strip"].firstMatch
        XCTAssertTrue(strip.exists)

        strip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        XCTAssertTrue(app.buttons["trip-detail-close"].isHittable)

        strip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(ready.exists)
        XCTAssertTrue(app.buttons["trip-detail-close"].isHittable)
    }

    func testMapOptionsLiveInTheTopRowMenu() {
        let app = launch()
        let menu = app.buttons["Map options"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        XCTAssertTrue(app.buttons["Weather hazards"].waitForExistence(timeout: 2)
                      || app.switches["Weather hazards"].waitForExistence(timeout: 2))
    }

    // MARK: Journey stack

    func testSwipingTheStackFlipsJourneysAndStopsAtTheEnds() {
        let app = launch()
        let stack = app.descendants(matching: .any)["trips-stack"].firstMatch
        XCTAssertTrue(stack.waitForExistence(timeout: 5))
        let first = visibleTripRows(app)
        XCTAssertFalse(first.isEmpty)

        stack.swipeDown()   // at the first journey: stays
        XCTAssertTrue(waitUntil { visibleTripRows(app) == first })
        XCTAssertEqual(visibleTripRows(app), first)

        stack.swipeUp()
        XCTAssertTrue(waitUntil { visibleTripRows(app) != first && !visibleTripRows(app).isEmpty })
        let second = visibleTripRows(app)
        XCTAssertFalse(second.isEmpty)
        XCTAssertNotEqual(second, first)
        XCTAssertTrue(stackValue(stack).hasPrefix("Journey 2 of"))

        stack.swipeDown()
        XCTAssertTrue(waitUntil { visibleTripRows(app) == first })
        XCTAssertEqual(visibleTripRows(app), first)
    }

    func testTappingARowInsideTheStackStillOpensTheTrip() {
        let app = launch()
        let stack = app.descendants(matching: .any)["trips-stack"].firstMatch
        XCTAssertTrue(stack.waitForExistence(timeout: 5))
        stack.swipeUp()
        XCTAssertTrue(waitUntil { stackValue(stack).hasPrefix("Journey 2 of") })
        let rows = visibleTripRows(app)
        XCTAssertFalse(rows.isEmpty)
        let row = app.buttons[rows[0]]
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["trip-detail-ready"].firstMatch.waitForExistence(timeout: 3))
        app.buttons["trip-detail-close"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertTrue(stackValue(stack).hasPrefix("Journey 2 of"), "closing returns to the same page")
    }

    /// From a journey with enough earlier journeys to fill the list's height,
    /// Show More holds the current card exactly where it is (spec:
    /// 2026-09-15-journey-stack-design.md).
    func testShowMoreFromALaterJourneyKeepsItsCardInPlace() {
        let app = launch()
        let stack = app.descendants(matching: .any)["trips-stack"].firstMatch
        XCTAssertTrue(stack.waitForExistence(timeout: 5))

        var info = pageAndCount(stackValue(stack))
        XCTAssertNotNil(info, "stack label didn't parse: \(stackValue(stack))")
        while let current = info, current.page < 4, current.page < current.count {
            stack.swipeUp()
            XCTAssertTrue(waitUntil { pageAndCount(stackValue(stack))?.page != current.page })
            info = pageAndCount(stackValue(stack))
        }
        guard let landed = info else { XCTFail("stack lost its label"); return }

        let rows = visibleTripRows(app)
        XCTAssertFalse(rows.isEmpty)
        let id = rows[0]
        let before = app.buttons[id].frame

        let toggle = app.buttons["trips-fold-toggle"]
        toggle.tap()
        XCTAssertTrue(waitUntil { toggle.label == "Show Less" })
        XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 3))
        let after = app.buttons[id].frame
        XCTAssertEqual(after.minY, before.minY, accuracy: 3,
                        "with enough journeys above, journey \(landed.page)'s card should not move")

        toggle.tap()
        XCTAssertTrue(stack.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntil { stackValue(stack).hasPrefix("Journey \(landed.page) of") })
        XCTAssertTrue(stackValue(stack).hasPrefix("Journey \(landed.page) of"))
    }

    /// From journey 2 there's only one journey above: holding the card still
    /// would leave an empty band, so per the amendment the list starts offset
    /// and the card rises into place, landing with no gap under the toggle.
    func testShowMoreFromTheSecondJourneyLeavesNoGapAboveTheList() {
        let app = launch()
        let stack = app.descendants(matching: .any)["trips-stack"].firstMatch
        XCTAssertTrue(stack.waitForExistence(timeout: 5))
        let firstRows = visibleTripRows(app)
        XCTAssertFalse(firstRows.isEmpty)
        let firstRowID = firstRows[0]

        stack.swipeUp()
        XCTAssertTrue(waitUntil { stackValue(stack).hasPrefix("Journey 2 of") })

        let toggle = app.buttons["trips-fold-toggle"]
        toggle.tap()
        XCTAssertTrue(waitUntil { toggle.label == "Show Less" })

        let firstRow = app.buttons[firstRowID]
        XCTAssertTrue(waitUntil { firstRow.isHittable })
        XCTAssertTrue(firstRow.isHittable, "the first journey should be reachable right above the current one")
        // The toggle's accessibility frame is only its text glyph (~18 pt),
        // centered inside its true 44 pt control row, so even a row landing
        // flush with the list's top reads ~21 pt below toggle.maxY (measured
        // on a settled, non-animating frame). A real leftover empty band
        // would be tens of points larger still (a whole card's height).
        let gap = firstRow.frame.minY - toggle.frame.maxY
        XCTAssertGreaterThanOrEqual(gap, -5, "the first journey's row shouldn't sit above the fold toggle")
        XCTAssertLessThanOrEqual(gap, 40, "no empty band between the fold toggle and the first journey")

        toggle.tap()
        XCTAssertTrue(stack.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntil { stackValue(stack).hasPrefix("Journey 2 of") })
    }
}
