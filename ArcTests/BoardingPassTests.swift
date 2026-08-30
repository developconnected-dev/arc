import XCTest
@testable import Arc

/// The BCBP decode, against the IATA Resolution 792 reference payload and
/// the ways real scans go wrong.
final class BoardingPassTests: XCTestCase {

    /// The canonical example from the IATA implementation guide.
    private let iataReference = "M1DESMARAIS/LUC       EABC123 YULFRAAC 0834 326J001A0025 100"

    func testDecodesTheIATAReferencePass() {
        let p = BoardingPass.parse(iataReference)
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.passengerName, "DESMARAIS/LUC")
        XCTAssertEqual(p?.bookingCode, "ABC123")
        XCTAssertEqual(p?.departureIATA, "YUL")
        XCTAssertEqual(p?.arrivalIATA, "FRA")
        XCTAssertEqual(p?.airlineCode, "AC")
        XCTAssertEqual(p?.flightNumber, "AC834")
        XCTAssertEqual(p?.julianDay, 326)
        XCTAssertEqual(p?.seat, "1A")
    }

    func testFlightDatePicksTheYearNearestToday() {
        let cal = Calendar(identifier: .gregorian)
        let p = BoardingPass.parse(iataReference)!   // day 326 ≈ Nov 22
        // Scanned in November: this year's day 326.
        let november = cal.date(from: DateComponents(year: 2026, month: 11, day: 20))!
        XCTAssertEqual(cal.component(.year, from: p.flightDate(near: november, calendar: cal)!), 2026)
        // Scanned in early January: LAST year's day 326 is nearer than
        // waiting ten months.
        let january = cal.date(from: DateComponents(year: 2027, month: 1, day: 3))!
        XCTAssertEqual(cal.component(.year, from: p.flightDate(near: january, calendar: cal)!), 2026)
    }

    func testSeatDePaddingAndWindowSeats() {
        // "014C" → "14C"
        let p = BoardingPass.parse(
            "M1ZERDICK/CARL        EXY7Z9Q ZRHVLCLX 2146 237Y014C0102 100")
        XCTAssertEqual(p?.flightNumber, "LX2146")
        XCTAssertEqual(p?.departureIATA, "ZRH")
        XCTAssertEqual(p?.arrivalIATA, "VLC")
        XCTAssertEqual(p?.seat, "14C")
    }

    func testNoSeatIsNilNotGarbage() {
        // Gate-assigned seating: the seat field carries a marker, not a seat.
        let p = BoardingPass.parse(
            "M1ZERDICK/CARL        EXY7Z9Q ZRHVLCLX 2146 237YGATE0102 100")
        XCTAssertNotNil(p)
        XCTAssertNil(p?.seat)
    }

    func testRejectsThingsThatAreNotBoardingPasses() {
        XCTAssertNil(BoardingPass.parse("https://example.com/checkin?code=ABC123"))
        XCTAssertNil(BoardingPass.parse(""))
        XCTAssertNil(BoardingPass.parse("M1TOO SHORT"))
        // Right shape, impossible day-of-year.
        XCTAssertNil(BoardingPass.parse(
            "M1ZERDICK/CARL        EXY7Z9Q ZRHVLCLX 2146 999Y014C0102 100"))
        // Digits where the airports should be.
        XCTAssertNil(BoardingPass.parse(
            "M1ZERDICK/CARL        EXY7Z9Q 123VLCLX 2146 237Y014C0102 100"))
    }

    func testFlightNumberDePadsButKeepsSuffix() {
        let p = BoardingPass.parse(
            "M1ZERDICK/CARL        EXY7Z9Q ZRHVLCLX 0034A237Y014C0102 100")
        XCTAssertEqual(p?.flightNumber, "LX34A")
    }
}
