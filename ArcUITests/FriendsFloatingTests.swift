import XCTest

/// Friends floats over the globe like My Trips
/// (docs/superpowers/specs/2026-09-16-friends-floating-design.md).
///
/// The demo feed (`-seedFriendsDemo`): Demo Friend flies demo-feed-1 and
/// demo-feed-2 and landed demo-past-1 yesterday; Second Friend flies
/// demo-feed-3. `-seedFriendRequestsDemo` adds two requests, new each launch.
@MainActor
final class FriendsFloatingTests: XCTestCase {
    /// No `-sheetLarge`: that starts Friends unfolded.
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-seedDemo", "-uiNoPrompt", "-seedFriendsDemo", "-tabFriends",
                               "-apiEndpoint", "http://127.0.0.1:9"] + extra
        app.launch()
        return app
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return condition() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return true
    }

    private func visibleFlightCards(_ app: XCUIApplication) -> [String] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "friend-trip-"))
            .allElementsBoundByIndex.filter { $0.isHittable }.map(\.identifier)
    }

    private func stack(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["friends-stack"].firstMatch
    }

    private func bell(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["friends-requests-bell"]
    }

    /// "Flight 2 of 3, Zurich to Vienna" / "Request 1 of 2, from Requester 1".
    private func stackValue(_ stack: XCUIElement) -> String {
        stack.value as? String ?? ""
    }

    private func pageAndCount(_ label: String, of kind: String = "Flight ") -> (page: Int, count: Int)? {
        guard let kindRange = label.range(of: kind) else { return nil }
        let rest = label[kindRange.upperBound...]
        guard let ofRange = rest.range(of: " of ") else { return nil }
        let countString = rest[ofRange.upperBound...].prefix { $0.isNumber }
        guard let page = Int(rest[rest.startIndex..<ofRange.lowerBound]), let count = Int(countString) else { return nil }
        return (page, count)
    }

    // MARK: Chips

    func testTheChipsNarrowTheStackAndAllWidensItAgain() {
        let app = launch()
        let stack = stack(app)
        XCTAssertTrue(stack.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil { stackValue(stack).hasPrefix("Flight 1 of 3") }, stackValue(stack))

        let all = app.buttons["friends-chip-all"]
        XCTAssertTrue(all.exists)
        XCTAssertTrue(all.isSelected, "All is the filter in force")
        XCTAssertTrue(app.buttons["friends-chip-add"].exists)
        let demo = app.buttons["friends-chip-friend-demo-friend"]
        let second = app.buttons["friends-chip-friend-demo-friend-2"]
        XCTAssertTrue(demo.exists)
        XCTAssertTrue(second.exists)

        demo.tap()
        XCTAssertTrue(waitUntil { stackValue(stack).hasPrefix("Flight 1 of 2") },
                      "Demo Friend has two flights: \(stackValue(stack))")
        XCTAssertTrue(demo.isSelected)
        XCTAssertFalse(all.isSelected)

        second.tap()
        // One card: no pager, just the card.
        XCTAssertTrue(waitUntil { !stack.exists }, "a single flight is not a stack")
        XCTAssertTrue(waitUntil { visibleFlightCards(app) == ["friend-trip-demo-feed-3"] },
                      "\(visibleFlightCards(app))")
        XCTAssertFalse(app.buttons["friends-fold-toggle"].exists, "nothing more to show")

        all.tap()
        XCTAssertTrue(stack.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntil { pageAndCount(stackValue(stack))?.count == 3 }, stackValue(stack))
    }

    // MARK: The stack

    func testSwipingTheStackFlipsFlightsAndStopsAtTheEnds() {
        let app = launch()
        let stack = stack(app)
        XCTAssertTrue(stack.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil { stackValue(stack).hasPrefix("Flight 1 of 3") }, stackValue(stack))
        let first = visibleFlightCards(app)
        XCTAssertEqual(first.count, 1, "folded, one card at a time")

        stack.swipeDown()   // the first flight: stays
        XCTAssertTrue(stackValue(stack).hasPrefix("Flight 1 of 3"))
        XCTAssertEqual(visibleFlightCards(app), first)

        stack.swipeUp()
        XCTAssertTrue(waitUntil { stackValue(stack).hasPrefix("Flight 2 of 3") }, stackValue(stack))
        XCTAssertTrue(waitUntil { visibleFlightCards(app) != first && visibleFlightCards(app).count == 1 })

        stack.swipeUp()
        XCTAssertTrue(waitUntil { stackValue(stack).hasPrefix("Flight 3 of 3") }, stackValue(stack))
        let last = visibleFlightCards(app)

        stack.swipeUp()     // the last flight: stays
        waitUntil(timeout: 1) { false }
        XCTAssertTrue(stackValue(stack).hasPrefix("Flight 3 of 3"), stackValue(stack))
        XCTAssertEqual(visibleFlightCards(app), last)

        stack.swipeDown()
        XCTAssertTrue(waitUntil { stackValue(stack).hasPrefix("Flight 2 of 3") }, stackValue(stack))
    }

    func testTappingACardOpensItAndClosingReturnsToTheSameCard() {
        let app = launch()
        let stack = stack(app)
        XCTAssertTrue(stack.waitForExistence(timeout: 5))
        stack.swipeUp()
        XCTAssertTrue(waitUntil { stackValue(stack).hasPrefix("Flight 2 of") }, stackValue(stack))
        XCTAssertTrue(waitUntil { visibleFlightCards(app).count == 1 })
        let id = visibleFlightCards(app)[0]

        app.buttons[id].tap()
        XCTAssertTrue(app.descendants(matching: .any)["trip-detail-ready"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["friends-fold-toggle"].exists, "the chrome hides behind the panel")

        app.buttons["trip-detail-close"].tap()
        XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntil { stackValue(stack).hasPrefix("Flight 2 of") }, "closing returns to the same card")
        XCTAssertTrue(waitUntil { visibleFlightCards(app) == [id] })
        XCTAssertEqual(app.buttons["friends-fold-toggle"].label, "Show More")
    }

    // MARK: Show More, Past Flights

    func testShowMoreListsTheFlightsAndPastFlightsAndShowLessFoldsBack() {
        let app = launch()
        let stack = stack(app)
        XCTAssertTrue(stack.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["friends-past-toggle"].exists, "Past Flights live only in the list")

        let toggle = app.buttons["friends-fold-toggle"]
        XCTAssertEqual(toggle.label, "Show More")
        toggle.tap()
        XCTAssertTrue(waitUntil { toggle.label == "Show Less" })
        XCTAssertTrue(waitUntil { visibleFlightCards(app).count == 3 }, "\(visibleFlightCards(app))")

        let past = app.buttons["friends-past-toggle"]
        XCTAssertTrue(past.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntil { past.isHittable })
        XCTAssertEqual(past.value as? String, "Collapsed")
        XCTAssertFalse(app.buttons["friend-trip-demo-past-1"].exists, "past flights wait behind their row")
        // Past Flights close the list, under the upcoming ones.
        let lastCard = app.buttons["friend-trip-demo-feed-3"]
        XCTAssertGreaterThan(past.frame.minY, lastCard.frame.minY)

        past.tap()
        XCTAssertTrue(waitUntil { past.value as? String == "Expanded" })
        let pastCard = app.buttons["friend-trip-demo-past-1"]
        XCTAssertTrue(pastCard.waitForExistence(timeout: 3))
        app.swipeUp()   // the list may need a scroll to bring it up
        XCTAssertTrue(waitUntil { pastCard.isHittable }, "the past flight shows under the row")

        toggle.tap()
        XCTAssertTrue(waitUntil { toggle.label == "Show More" })
        XCTAssertTrue(waitUntil { visibleFlightCards(app).count == 1 }, "\(visibleFlightCards(app))")
        XCTAssertTrue(stack.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["friends-past-toggle"].exists)
    }

    // MARK: The requests' bell

    private func launchWithRequests() -> XCUIApplication {
        launch(["-seedFriendRequestsDemo"])
    }

    func testNoRequestsNoBell() {
        let app = launch()
        XCTAssertTrue(stack(app).waitForExistence(timeout: 5))
        XCTAssertFalse(bell(app).exists)
    }

    func testTheBellCarriesTheUnreadRequestsAndSwapsToThem() {
        let app = launchWithRequests()
        let bell = bell(app)
        XCTAssertTrue(bell.waitForExistence(timeout: 5))
        XCTAssertEqual(bell.label, "Friend requests")
        XCTAssertEqual(bell.value as? String, "2 unread", "both requests are new")

        bell.tap()
        let stack = stack(app)
        XCTAssertTrue(waitUntil(timeout: 4) { stackValue(stack).hasPrefix("Request 1 of 2") }, stackValue(stack))
        XCTAssertEqual(stack.label, "Friend requests")
        XCTAssertTrue(app.buttons["friend-request-accept"].exists)
        XCTAssertTrue(app.buttons["friend-request-decline"].exists)
        XCTAssertTrue(waitUntil { bell.label == "Back to friends' flights" }, "the bell becomes the X")
        XCTAssertTrue(visibleFlightCards(app).isEmpty, "the flights are behind the requests")

        stack.swipeUp()
        XCTAssertTrue(waitUntil { stackValue(stack).hasPrefix("Request 2 of 2") }, stackValue(stack))
        stack.swipeUp()     // the last request: stays
        waitUntil(timeout: 1) { false }
        XCTAssertTrue(stackValue(stack).hasPrefix("Request 2 of 2"))
        stack.swipeDown()
        XCTAssertTrue(waitUntil { stackValue(stack).hasPrefix("Request 1 of 2") }, stackValue(stack))

        // The X returns to the flight the stack was on; both were seen.
        bell.tap()
        XCTAssertTrue(waitUntil(timeout: 4) { stackValue(stack).hasPrefix("Flight 1 of 3") }, stackValue(stack))
        XCTAssertTrue(waitUntil { bell.label == "Friend requests" })
        XCTAssertEqual(bell.value as? String ?? "", "", "flipped to, so read")
        XCTAssertEqual(visibleFlightCards(app).count, 1)
    }

    func testTheXReturnsToTheFlightTheStackWasOn() {
        let app = launchWithRequests()
        let stack = stack(app)
        XCTAssertTrue(stack.waitForExistence(timeout: 5))
        stack.swipeUp()
        XCTAssertTrue(waitUntil { stackValue(stack).hasPrefix("Flight 2 of") }, stackValue(stack))
        let flight = stackValue(stack)

        let bell = bell(app)
        bell.tap()
        XCTAssertTrue(waitUntil(timeout: 4) { stackValue(stack).hasPrefix("Request 1 of") }, stackValue(stack))
        bell.tap()
        XCTAssertTrue(waitUntil(timeout: 4) { stackValue(stack).hasPrefix("Flight ") }, stackValue(stack))
        XCTAssertEqual(stackValue(stack), flight, "the flights return where they were")
    }

    func testAnsweringTheLastRequestBringsTheFlightsBackAndTakesTheBellAway() {
        let app = launchWithRequests()
        let bell = bell(app)
        XCTAssertTrue(bell.waitForExistence(timeout: 5))
        bell.tap()
        let stack = stack(app)
        XCTAssertTrue(waitUntil(timeout: 4) { stackValue(stack).hasPrefix("Request 1 of 2") }, stackValue(stack))

        app.buttons["friend-request-accept"].tap()
        // One left: still the requests, as a single card.
        XCTAssertTrue(waitUntil(timeout: 3) { !stack.exists }, "one request is not a stack")
        XCTAssertTrue(app.buttons["friend-request-decline"].waitForExistence(timeout: 3))
        XCTAssertTrue(bell.exists)
        XCTAssertEqual(bell.label, "Back to friends' flights")

        app.buttons["friend-request-decline"].tap()
        XCTAssertTrue(waitUntil(timeout: 4) { !bell.exists }, "the bell goes with the last request")
        XCTAssertTrue(waitUntil(timeout: 4) { stackValue(stack).hasPrefix("Flight 1 of 3") },
                      "the flights are back without anyone asking: \(stackValue(stack))")
        XCTAssertFalse(app.buttons["friend-request-accept"].exists)
        XCTAssertEqual(visibleFlightCards(app).count, 1)
    }
}
