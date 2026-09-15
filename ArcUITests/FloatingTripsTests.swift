import XCTest

@MainActor
final class FloatingTripsTests: XCTestCase {
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-seedDemo", "-uiNoPrompt", "-apiEndpoint", "http://127.0.0.1:9"] + extra
        app.launch()
        return app
    }

    func testFoldedShowsOnlyTheNextJourneyAndUnfoldsAndFoldsBack() {
        let app = launch()
        let next = app.buttons["trip-row-LX14"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["trip-row-LX1413"].exists, "a folded stack builds only the next journey")

        let toggle = app.buttons["trips-fold-toggle"]
        XCTAssertEqual(toggle.label, "Show More")
        toggle.tap()
        let later = app.buttons["trip-row-LX1413"]
        XCTAssertTrue(later.waitForExistence(timeout: 3))
        XCTAssertTrue(later.isHittable)
        XCTAssertEqual(toggle.label, "Show Less")

        toggle.tap()
        XCTAssertTrue(later.waitForNonExistence(timeout: 3))
        XCTAssertTrue(next.isHittable)
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
}
