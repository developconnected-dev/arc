import XCTest
@testable import Arc

/// The vetting gate both extraction lanes share: what a model claims about a
/// booking is believed only when it looks like a flight on a plausible date.
final class BookingExtractorTests: XCTestCase {

    private let cal = Calendar(identifier: .gregorian)
    private var today: Date {
        cal.date(from: DateComponents(year: 2026, month: 8, day: 30))!
    }
    private func item(_ n: String, _ d: String) -> FlightAPIClient.ParsedFlightItem {
        .init(flightNumber: n, date: d)
    }

    func testKeepsRealFlightsAndNormalizes() {
        let out = BookingExtractor.vetted(
            [item("lx 2146", "2026-09-14"), item("U2 8437", "2026-09-18")],
            near: today)
        XCTAssertEqual(out.map(\.flightNumber), ["LX2146", "U28437"])
        XCTAssertEqual(out.map(\.date), ["2026-09-14", "2026-09-18"])
    }

    func testRejectsInventions() {
        let out = BookingExtractor.vetted([
            item("LX2146", "2019-03-08"),      // date from another life
            item("122146", "2026-09-14"),      // all-digit "designator" — a row, not an airline
            item("LX", "2026-09-14"),          // no number at all
            item("LX21467", "2026-09-14"),     // five digits is not a flight number
            item("LX2146", "14 September"),    // unparseable date survives no lane
        ], near: today)
        XCTAssertTrue(out.isEmpty)
    }

    func testOperationalSuffixAndDigitCarrierSurvive() {
        let out = BookingExtractor.vetted(
            [item("LX34A", "2026-09-01"), item("U22146", "2026-09-01")], near: today)
        XCTAssertEqual(out.map(\.flightNumber), ["LX34A", "U22146"])
    }

    func testDuplicateLegsCollapseButOrderHolds() {
        // Confirmations restate each leg in the summary and the fare table.
        let out = BookingExtractor.vetted([
            item("LX2146", "2026-09-14"),
            item("VY1275", "2026-09-18"),
            item("LX2146", "2026-09-14"),
        ], near: today)
        XCTAssertEqual(out.map(\.flightNumber), ["LX2146", "VY1275"])
    }

    func testRecentPastStaysBelievable() {
        // People paste yesterday's confirmation too; a year is the fence,
        // not the clock's own midnight.
        let out = BookingExtractor.vetted([item("LX2146", "2026-08-20")], near: today)
        XCTAssertEqual(out.count, 1)
    }
}
