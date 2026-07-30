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
