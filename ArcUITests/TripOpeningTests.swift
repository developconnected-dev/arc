import XCTest

@MainActor
final class TripOpeningTests: XCTestCase {
    private func launch(friends: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-seedDemo", "-uiNoPrompt", "-sheetLarge", "-apiEndpoint", "http://127.0.0.1:9"]
        if friends { app.launchArguments += ["-seedFriendsDemo", "-tabFriends"] }
        app.launch()
        return app
    }

    private func cycle(_ app: XCUIApplication, rows: [String]) {
        for identifier in rows {
            let row = app.buttons[identifier]
            XCTAssertTrue(row.waitForExistence(timeout: 5), "List didn't return for \(identifier)")
            row.tap()
            let ready = app.descendants(matching: .any)["trip-detail-ready"].firstMatch
            XCTAssertTrue(ready.waitForExistence(timeout: 3), "Opening stuck for \(identifier)")
            let close = app.buttons["Close trip details"]
            XCTAssertTrue(close.isHittable)
            close.tap()
            XCTAssertTrue(row.waitForExistence(timeout: 3), "Closing stuck for \(identifier)")
        }
    }

    func testOpenBackThenAnotherOwnFlightRepeatedly() {
        let app = launch()
        cycle(app, rows: ["trip-row-LX14", "trip-row-LX1413", "trip-row-LX14", "trip-row-LX1413"])
    }

    func testOpenBackThenAnotherFriendsFlightRepeatedly() {
        let app = launch(friends: true)
        cycle(app, rows: ["friend-trip-demo-feed-1", "friend-trip-demo-feed-2",
                          "friend-trip-demo-feed-1", "friend-trip-demo-feed-2"])
    }

    func testCloseImmediatelyThenOpenAnotherFlight() {
        let app = launch()
        let first = app.buttons["trip-row-LX14"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap()
        let close = app.buttons["Close trip details"]
        XCTAssertTrue(close.waitForExistence(timeout: 2))
        close.tap()
        cycle(app, rows: ["trip-row-LX1413", "trip-row-LX14"])
    }
    func testSwitchingBetweenFriendsAndMyTripsDoesNotReuseAnOldTransition() {
        let app = launch(friends: true)
        cycle(app, rows: ["friend-trip-demo-feed-1"])
        app.tabBars.buttons["My Trips"].tap()
        cycle(app, rows: ["trip-row-LX14"])
        app.tabBars.buttons["Friends"].tap()
        cycle(app, rows: ["friend-trip-demo-feed-2"])
    }
    func testSharedFlightShowsOneRowAndEveryTravellerIncludingYou() {
        let app = XCUIApplication()
        app.launchArguments = ["-seedDemo", "-uiNoPrompt", "-sheetLarge", "-seedFriendsDemo",
            "-seedGroupedFriendsDemo", "-tabFriends", "-apiEndpoint", "http://127.0.0.1:9"]
        app.launch()
        let row = app.buttons["friend-trip-demo-feed-1"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "friend-trip-")).count, 1)
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["trip-detail-ready"].firstMatch.waitForExistence(timeout: 3))
        for index in 1...4 { XCTAssertTrue(app.staticTexts["Friend \(index)"].exists) }
        XCTAssertTrue(app.staticTexts["You’re on this flight"].exists)
        app.buttons["Close trip details"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3))
    }
}
