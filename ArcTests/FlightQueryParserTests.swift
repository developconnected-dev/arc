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

    // MARK: date formats added for the local route parser

    func testAbbreviatedMonth() {
        let d = FlightQueryParser.findDate(in: "Athens to Munich 18 Sep", now: now)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        XCTAssertEqual(cal.component(.month, from: d!), 9)
        XCTAssertEqual(cal.component(.day, from: d!), 18)
    }

    func testSwissNumericDate() {
        let d = FlightQueryParser.findDate(in: "Zurich to Hamburg 18.09.2026", now: now)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        XCTAssertEqual(cal.component(.day, from: d!), 18)
        XCTAssertEqual(cal.component(.month, from: d!), 9)
        XCTAssertEqual(cal.component(.year, from: d!), 2026)
    }

    /// "5.3." with no year, already past → next year.
    func testSwissNumericDateRollsForward() {
        let d = FlightQueryParser.findDate(in: "ZRH to HAM 5.3.", now: now)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        XCTAssertEqual(cal.component(.month, from: d!), 3)
        XCTAssertEqual(cal.component(.year, from: d!), 2027)
    }

    // MARK: parseRoute — local "city to city" resolution

    func testParsesPlainRoute() {
        let r = FlightQueryParser.parseRoute("Athens to Munich 18 September", now: now)
        XCTAssertEqual(r?.depIATA, "ATH")
        XCTAssertEqual(r?.arrIATA, "MUC")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        XCTAssertEqual(cal.component(.day, from: r!.date!), 18)
    }

    func testParsesIATARoute() {
        let r = FlightQueryParser.parseRoute("ZRH to HAM tomorrow", now: now)
        XCTAssertEqual(r?.depIATA, "ZRH")
        XCTAssertEqual(r?.arrIATA, "HAM")
    }

    /// Multi-airport metros resolve to the primary — the same single-airport
    /// choice the AI parser makes.
    func testMultiAirportCityUsesPrimary() {
        XCTAssertEqual(FlightQueryParser.parseRoute("London to Zurich", now: now)?.depIATA, "LHR")
    }

    func testNoiseWordsAndCase() {
        let r = FlightQueryParser.parseRoute("add a flight from athens to munich on 18 September", now: now)
        XCTAssertEqual(r?.depIATA, "ATH")
        XCTAssertEqual(r?.arrIATA, "MUC")
    }

    /// A flight number in the text means it's not a route query.
    func testFlightNumberIsNotARoute() {
        XCTAssertNil(FlightQueryParser.parseRoute("LX1413 to Munich", now: now))
    }

    /// "on 18" must never resolve as Nauru Airlines ON18.
    func testStopwordsAreNotAirlineCodes() {
        XCTAssertNil(FlightQueryParser.findCode(in: "Athens to Munich on 18 September"))
    }

    func testUnresolvableCityFallsThrough() {
        XCTAssertNil(FlightQueryParser.parseRoute("Xqzw to Munich", now: now))
    }

    // MARK: German queries — the family's other language

    func testGermanRouteWithUmlautsAndNach() {
        let r = FlightQueryParser.parseRoute("Zürich nach Hamburg 18. September", now: now)
        XCTAssertEqual(r?.depIATA, "ZRH")
        XCTAssertEqual(r?.arrIATA, "HAM")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        XCTAssertEqual(cal.component(.day, from: r!.date!), 18)
    }

    func testGermanExonymsAndNoise() {
        let r = FlightQueryParser.parseRoute("Flug von Wien nach Lissabon", now: now)
        XCTAssertEqual(r?.depIATA, "VIE")
        XCTAssertEqual(r?.arrIATA, "LIS")
    }

    func testGermanRelativeDates() {
        let cal = Calendar.current
        let morgen = FlightQueryParser.parseRoute("Zürich nach München morgen", now: now)
        XCTAssertEqual(morgen?.arrIATA, "MUC")
        XCTAssertEqual(cal.startOfDay(for: morgen!.date!),
                       cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: now)!))
        let uebermorgen = FlightQueryParser.findDate(in: "Wien nach Rom übermorgen", now: now)
        XCTAssertEqual(cal.startOfDay(for: uebermorgen!),
                       cal.startOfDay(for: cal.date(byAdding: .day, value: 2, to: now)!))
    }

    func testGermanMonths() {
        let d = FlightQueryParser.findDate(in: "Genf nach Prag 18 Okt", now: now)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        XCTAssertEqual(cal.component(.month, from: d!), 10)
        let mai = FlightQueryParser.findDate(in: "5 Mai", now: now)
        XCTAssertEqual(cal.component(.month, from: mai!), 5)
    }
}

// MARK: - The free-text fallback must not answer about somewhere else

@MainActor
final class RouteFallbackGuardTests: XCTestCase {
    private func result(_ number: String, _ dep: String, _ arr: String)
        -> FlightAPIClient.FlightSearchResult {
        FlightAPIClient.FlightSearchResult(
            flight_number: number, airline_name: "", airline_iata: "",
            dep_iata: dep, arr_iata: arr, dep_city: nil, arr_city: nil,
            dep_scheduled: "", arr_scheduled: "", dep_actual: nil, arr_actual: nil,
            status: "scheduled", dep_gate: nil, dep_terminal: nil, arr_gate: nil,
            arr_terminal: nil, arr_baggage: nil, delay: nil, aircraft_type: nil,
            aircraft_registration: nil, aircraft_icao24: nil,
            dep_lat: nil, dep_lon: nil, arr_lat: nil, arr_lon: nil)
    }

    /// Syros resolves locally, and correctly, to JSY.
    func testSyrosResolvesToItsOwnAirport() {
        let route = FlightQueryParser.parseRoute("Syros to Athens 18 September")
        XCTAssertEqual(route?.depIATA, "JSY")
        XCTAssertEqual(route?.arrIATA, "ATH")
    }

    /// The reported bug: the provider has no Syros coverage, the free-text
    /// parser read "Syros" as Santorini, and JTR → ATH flights were shown as
    /// the answer to a question about JSY.
    func testSantoriniResultsAreRejectedForASyrosSearch() {
        let route = FlightQueryParser.parseRoute("Syros to Athens 18 September")
        let santorini = [result("A3351", "JTR", "ATH"),
                         result("FR1233", "JTR", "ATH"),
                         result("GQ341", "JTR", "ATH")]
        XCTAssertTrue(AddFlightView.keepingOnlyRoute(route, in: santorini).isEmpty,
                      "a search for JSY must never be answered with JTR flights")
    }

    /// The guard must not throw away correct answers.
    func testResultsOnTheNamedRouteSurvive() {
        let route = FlightQueryParser.parseRoute("Athens to Munich 18 September")
        let mixed = [result("LH1751", "ATH", "MUC"),
                     result("A3351", "JTR", "ATH"),
                     result("LH1755", "ath", "muc")]      // casing must not matter
        let kept = AddFlightView.keepingOnlyRoute(route, in: mixed).map(\.flight_number)
        XCTAssertEqual(kept, ["LH1751", "LH1755"])
    }

    /// Genuinely free text — a pasted booking, a codeshare number — has no
    /// locally-understood route, so nothing is filtered and the fallback keeps
    /// doing the job it exists for.
    func testFreeTextWithNoLocalRouteIsUnfiltered() {
        let route = FlightQueryParser.parseRoute("A31653 on the 18th of September")
        XCTAssertNil(route)
        let results = [result("LH1751", "ATH", "MUC")]
        XCTAssertEqual(AddFlightView.keepingOnlyRoute(route, in: results).count, 1)
    }
}
