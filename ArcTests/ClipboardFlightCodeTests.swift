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
