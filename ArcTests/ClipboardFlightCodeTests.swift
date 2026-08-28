import XCTest
@testable import Arc

/// The clipboard pill hands whatever was pasted to this: a bare flight number
/// goes straight into the search, anything longer (a booking email) is passed
/// to the Add screen's parser rather than being thrown away.
@MainActor
final class ClipboardFlightCodeTests: XCTestCase {
    func testAcceptsBareFlightNumbers() {
        XCTAssertEqual(ArcRootView.flightCode(in: "LX1413"), "LX1413")
        XCTAssertEqual(ArcRootView.flightCode(in: "lx1413"), "LX1413")
        XCTAssertEqual(ArcRootView.flightCode(in: "LX 1413"), "LX1413")
        XCTAssertEqual(ArcRootView.flightCode(in: "  A3 1653\n"), "A31653")
    }

    /// Airline codes can contain a digit (A3 Aegean, 4U, U2), and numbers run
    /// one to four digits.
    func testAcceptsAirlineCodesWithDigitsAndShortNumbers() {
        XCTAssertEqual(ArcRootView.flightCode(in: "4U8501"), "4U8501")
        XCTAssertEqual(ArcRootView.flightCode(in: "GQ21"), "GQ21")
        XCTAssertEqual(ArcRootView.flightCode(in: "BA1"), "BA1")
    }

    func testRejectsThingsThatAreNotFlightNumbers() {
        XCTAssertNil(ArcRootView.flightCode(in: ""))
        XCTAssertNil(ArcRootView.flightCode(in: "hello"))
        XCTAssertNil(ArcRootView.flightCode(in: "1413"))
        XCTAssertNil(ArcRootView.flightCode(in: "LX14135"))     // five digits
        XCTAssertNil(ArcRootView.flightCode(in: "ZRHLHR"))
    }

    /// A whole confirmation email is not a code — it must fall through so the
    /// parser gets it instead.
    func testRejectsLongerTextSoItReachesTheParser() {
        let email = "Your Swiss booking is confirmed: LX1413 on 30 July 2026, Belgrade to Zurich."
        XCTAssertNil(ArcRootView.flightCode(in: email))
    }
}

@MainActor
final class ArcDeepLinkTests: XCTestCase {
    func testParsesFlightUUID() {
        let id = UUID()
        XCTAssertEqual(ArcDeepLink.parse(ArcDeepLink.flight(id: id)), .flight(id: id))
    }

    func testParsesFlightIdentity() {
        let url = ArcDeepLink.flight(number: "LX14", dep: "ZRH", arr: "JFK")
        XCTAssertEqual(ArcDeepLink.parse(url),
                       .flightIdentity(number: "LX14", dep: "ZRH", arr: "JFK"))
    }

    func testParsesDirectionsWithTerminal() {
        let url = URL(string: "arc://directions/ZRH?t=2")!
        XCTAssertEqual(ArcDeepLink.parse(url), .directions(iata: "ZRH", terminal: "2"))
    }

    func testParsesFriendInvite() {
        XCTAssertEqual(ArcDeepLink.parse(URL(string: "arc://friend/abc123")!), .friend(code: "abc123"))
    }

    /// A tap on a FRIEND's Live Activity routes to the friend's flight.
    /// Before friendFlightId existed the card's URL resolved its flight
    /// number against the viewer's OWN store — a switch to My Trips with
    /// nothing opened.
    func testFriendCardURLRoutesToTheFriendsFlight() {
        let rowId = UUID().uuidString
        var attrs = FlightActivityAttributes(
            flightNumber: "LX2146", departureIATA: "ZRH", arrivalIATA: "VLC",
            departureCity: "Zurich", arrivalCity: "Valencia", airline: "Swiss",
            aircraftType: nil, seat: nil)
        attrs.friendName = "Aram"
        attrs.friendFlightId = rowId
        XCTAssertEqual(ArcDeepLink.parse(ArcDeepLink.url(for: attrs)), .friendFlight(id: rowId))
        // An OWN card is untouched by the new field.
        attrs.friendName = nil
        attrs.flightId = UUID().uuidString
        if case .flight = ArcDeepLink.parse(ArcDeepLink.url(for: attrs)) {} else {
            XCTFail("own card should still route by flight id")
        }
    }

    func testLiveActivityURLPrefersFlightId() {
        let id = UUID()
        let attrs = FlightActivityAttributes(
            flightNumber: "LX14", departureIATA: "ZRH", arrivalIATA: "JFK",
            departureCity: "Zurich", arrivalCity: "New York",
            airline: "Swiss", aircraftType: nil, seat: nil,
            flightId: id.uuidString)
        XCTAssertEqual(ArcDeepLink.parse(ArcDeepLink.url(for: attrs)), .flight(id: id))
    }

    func testLiveActivityURLFallsBackToIdentity() {
        let attrs = FlightActivityAttributes(
            flightNumber: "LX14", departureIATA: "ZRH", arrivalIATA: "JFK",
            departureCity: "Zurich", arrivalCity: "New York",
            airline: "Swiss", aircraftType: nil, seat: nil)
        XCTAssertEqual(ArcDeepLink.parse(ArcDeepLink.url(for: attrs)),
                       .flightIdentity(number: "LX14", dep: "ZRH", arr: "JFK"))
    }

    func testIgnoresUnknownSchemes() {
        XCTAssertNil(ArcDeepLink.parse(URL(string: "https://example.com")!))
    }

    /// Regression: the identity form has NO path, and `lastPathComponent` hands
    /// back the host for that shape — so `arc://flight?number=…` and
    /// `arc://flight/<uuid>` were being told apart by a fragile comparison.
    func testTellsTheTwoFlightFormsApart() {
        XCTAssertEqual(
            ArcDeepLink.parse(URL(string: "arc://flight?number=LX14&dep=ZRH&arr=JFK")!),
            .flightIdentity(number: "LX14", dep: "ZRH", arr: "JFK"))
        let id = UUID()
        XCTAssertEqual(ArcDeepLink.parse(URL(string: "arc://flight/\(id.uuidString)")!), .flight(id: id))
    }

    func testIgnoresIncompleteOrUnknownArcLinks() {
        XCTAssertNil(ArcDeepLink.parse(URL(string: "arc://flight")!))
        XCTAssertNil(ArcDeepLink.parse(URL(string: "arc://flight?number=LX14")!))   // no route
        XCTAssertNil(ArcDeepLink.parse(URL(string: "arc://directions")!))
        XCTAssertNil(ArcDeepLink.parse(URL(string: "arc://friend")!))
        XCTAssertNil(ArcDeepLink.parse(URL(string: "arc://something/else")!))
    }

    func testDirectionsWithoutTerminal() {
        XCTAssertEqual(ArcDeepLink.parse(URL(string: "arc://directions/zrh")!),
                       .directions(iata: "ZRH", terminal: nil))
    }

    // MARK: - Notification taps route the same way links do

    func testNotificationUserInfoResolvesToThatFlight() {
        let id = UUID()
        XCTAssertEqual(
            ArcDeepLink.destination(fromNotificationUserInfo: [ArcOpenFlightInfo.id: id.uuidString]),
            .flight(id: id))
    }

    func testNotificationUserInfoFallsBackToIdentity() {
        XCTAssertEqual(
            ArcDeepLink.destination(fromNotificationUserInfo: [
                ArcOpenFlightInfo.number: "LX14",
                ArcOpenFlightInfo.dep: "ZRH",
                ArcOpenFlightInfo.arr: "JFK",
            ]),
            .flightIdentity(number: "LX14", dep: "ZRH", arr: "JFK"))
    }

    /// Notifications that aren't about one flight (a friend is at your airport)
    /// must not hijack the launch and open something arbitrary.
    func testNotificationWithoutAFlightResolvesToNothing() {
        XCTAssertNil(ArcDeepLink.destination(fromNotificationUserInfo: [:]))
        XCTAssertNil(ArcDeepLink.destination(fromNotificationUserInfo: ["other": "value"]))
        XCTAssertNil(ArcDeepLink.destination(fromNotificationUserInfo: [ArcOpenFlightInfo.id: "not-a-uuid"]))
    }

    func testWidgetFlightURLPrefersUUID() {
        let id = UUID()
        let f = WidgetFlight(
            id: id.uuidString, flightNumber: "LX14", airline: "Swiss",
            departureIATA: "ZRH", arrivalIATA: "JFK",
            departureCity: "Zurich", arrivalCity: "New York",
            scheduledDeparture: .now, scheduledArrival: .now.addingTimeInterval(3600),
            status: "scheduled", delayMinutes: 0, departureGate: nil, progress: 0)
        XCTAssertEqual(ArcDeepLink.parse(ArcDeepLink.flight(widget: f)), .flight(id: id))
    }
}
