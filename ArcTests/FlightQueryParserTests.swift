import XCTest
@testable import Arc

@MainActor
final class FlightQueryParserTests: XCTestCase {
    private let now = DateHelpers.parseAPIDate("2026-07-30T12:00:00.000Z")!

    // MARK: splitCode — the reported bug

    /// The old split took "everything before the first digit", turning A31653
    /// into airline "A" + flight "31653" and resolving to the wrong airline.
    func testSplitsDesignatorsThatContainDigits() {
        XCTAssertEqual(FlightQueryParser.splitCode("A31653")?.designator, "A3")
        XCTAssertEqual(FlightQueryParser.splitCode("A31653")?.number, "1653")
        XCTAssertEqual(FlightQueryParser.splitCode("4U8501")?.designator, "4U")
        XCTAssertEqual(FlightQueryParser.splitCode("U2123")?.designator, "U2")
        XCTAssertEqual(FlightQueryParser.splitCode("6E455")?.designator, "6E")
    }

    func testSplitsOrdinaryAndICAOCodes() {
        XCTAssertEqual(FlightQueryParser.splitCode("LX1413")?.designator, "LX")
        XCTAssertEqual(FlightQueryParser.splitCode("LX1413")?.number, "1413")
        XCTAssertEqual(FlightQueryParser.splitCode("lx 1413")?.number, "1413")
        XCTAssertEqual(FlightQueryParser.splitCode("GQ21")?.number, "21")
        // Three letters = ICAO designator.
        XCTAssertEqual(FlightQueryParser.splitCode("BAW123")?.designator, "BAW")
    }

    func testRejectsNonCodes() {
        XCTAssertNil(FlightQueryParser.splitCode("1413"))
        XCTAssertNil(FlightQueryParser.splitCode("SEPTEMBER"))
        XCTAssertNil(FlightQueryParser.splitCode("LX14135"))
    }

    // MARK: findCode in a sentence

    /// The exact phrasing that came back wrong.
    func testFindsCodeInTheReportedSentence() {
        let q = FlightQueryParser.parse("Athens to Munich on the 18th of September A31653", now: now)
        XCTAssertEqual(q?.code, "A31653")
    }

    func testIgnoresOrdinalsThatLookLikeCodes() {
        // "18TH" must not read as designator "18" + number… nor swallow the code.
        XCTAssertEqual(FlightQueryParser.parse("18th of September LX8", now: now)?.code, "LX8")
    }

    func testResolvesAirlineNamePlusNumber() {
        XCTAssertEqual(FlightQueryParser.parse("Swiss 1413 tomorrow", now: now)?.code, "LX1413")
    }

    // MARK: dates

    func testRelativeDates() {
        let cal = Calendar.current
        let tomorrow = FlightQueryParser.parse("LX1413 tomorrow", now: now)?.date
        XCTAssertEqual(cal.component(.day, from: tomorrow!), cal.component(.day, from: now) + 1)
        XCTAssertNotNil(FlightQueryParser.parse("LX1413 today", now: now)?.date)
    }

    func testSpokenDate() {
        let d = FlightQueryParser.parse("A31653 on the 18th of September", now: now)?.date
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        XCTAssertEqual(cal.component(.month, from: d!), 9)
        XCTAssertEqual(cal.component(.day, from: d!), 18)
        XCTAssertEqual(cal.component(.year, from: d!), 2026)
    }

    /// A day/month already past means next year, not a date behind us.
    func testBareDateRollsToNextYear() {
        let d = FlightQueryParser.parse("LX1413 on 5 March", now: now)?.date
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        XCTAssertEqual(cal.component(.year, from: d!), 2027)
    }

    func testNoDateMeansNil() {
        XCTAssertNil(FlightQueryParser.parse("LX1413", now: now)?.date)
    }

    func testGibberishParsesToNothing() {
        XCTAssertNil(FlightQueryParser.parse("hello there", now: now))
    }
}
