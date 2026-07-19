import XCTest
@testable import Arc

final class ReferenceDataTests: XCTestCase {
    private func fixture() -> ReferenceData {
        let airports = [
            AirportRef(iata: "ZRH", icao: "LSZH", name: "Zurich Airport", city: "Zurich",
                       country: "CH", lat: 47.4647, lon: 8.5492, tz: "Europe/Zurich"),
            AirportRef(iata: "ZAG", icao: "LDZA", name: "Zagreb Airport", city: "Zagreb",
                       country: "HR", lat: 45.743, lon: 16.0688, tz: "Europe/Zagreb"),
            AirportRef(iata: "JFK", icao: "KJFK", name: "John F Kennedy", city: "New York",
                       country: "US", lat: 40.6413, lon: -73.7781, tz: "America/New_York"),
        ]
        let airlines = [
            AirlineRef(iata: "LX", icao: "SWR", name: "Swiss", callsign: "SWISS", country: "CH"),
            AirlineRef(iata: "U2", icao: "EZY", name: "easyJet", callsign: "EASY", country: "GB"),
        ]
        return ReferenceData(airports: airports, airlines: airlines)
    }

    func testAirportLookupByIATA() {
        XCTAssertEqual(fixture().airport("zrh")?.city, "Zurich")
    }

    func testTimezoneResolves() {
        XCTAssertEqual(fixture().timezone("JFK")?.identifier, "America/New_York")
    }

    func testAirportSearchRanksExactIATAFirst() {
        let r = fixture().searchAirports("ZA")   // ZAG prefix, not ZRH
        XCTAssertEqual(r.first?.iata, "ZAG")
    }

    func testAirportSearchByCity() {
        XCTAssertEqual(fixture().searchAirports("New York").first?.iata, "JFK")
    }

    func testAirlineSearchByCode() {
        XCTAssertEqual(fixture().searchAirlines("LX").first?.name, "Swiss")
    }

    func testAirlineSearchByName() {
        XCTAssertEqual(fixture().searchAirlines("easy").first?.iata, "U2")
    }
}
