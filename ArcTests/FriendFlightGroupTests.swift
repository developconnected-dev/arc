import XCTest
@testable import Arc

@MainActor
final class FriendFlightGroupTests: XCTestCase {
    private func item(_ id: String, user: String, number: String = "GQ21",
                      from: String = "JSY", to: String = "ATH",
                      departure: String = "2026-09-18T08:10:00Z",
                      updated: String = "2026-09-15T00:00:00Z", delay: Int = 0) throws -> FriendsStore.FeedItem {
        let json: [String: Any] = ["id": id, "user_id": user, "flight_number": number,
            "airline": "Sky Express", "departure_iata": from, "arrival_iata": to,
            "departure_city": "Syros", "arrival_city": "Athens", "scheduled_departure": departure,
            "scheduled_arrival": "2026-09-18T08:45:00Z", "status": "scheduled",
            "delay_minutes": delay, "progress": 0, "updated_at": updated]
        let flight = try JSONDecoder().decode(ArcSupabase.SharedFlight.self,
            from: JSONSerialization.data(withJSONObject: json))
        let person = ArcSupabase.ArcUser(id: user, display_name: user, handle: user,
            avatar_url: nil, home_airport: nil, nationality: nil)
        return .init(user: person, flight: flight)
    }

    func testSameFlightGroupsAcrossFormattingAndTimeZones() throws {
        let a = try item("a", user: "A")
        let b = try item("b", user: "B", number: "gq 21", departure: "2026-09-18T11:10:00+03:00")
        let groups = FriendFlightGroup.group([a, b])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].users.map(\.id)), ["A", "B"])
        XCTAssertEqual(groups[0].id, FriendFlightGroup.group([b, a])[0].id)
    }

    func testDifferentDatesRoutesAndDeparturesStaySeparate() throws {
        let items = try [item("a", user: "A"),
            item("b", user: "B", departure: "2026-09-19T08:10:00Z"),
            item("c", user: "C", to: "SKG"),
            item("d", user: "D", departure: "2026-09-18T10:10:00Z")]
        XCTAssertEqual(FriendFlightGroup.group(items).count, 4)
    }

    func testNewestCopySuppliesStatusWithoutDuplicatingAPerson() throws {
        let a = try item("a", user: "A")
        let b = try item("b", user: "A", updated: "2026-09-15T01:00:00Z", delay: 30)
        let c = try item("c", user: "B")
        let group = FriendFlightGroup.group([a, b, c])[0]
        XCTAssertEqual(group.users.count, 2)
        XCTAssertEqual(group.representative.flight.delay_minutes, 30)
    }

    func testOnlyAnExactOwnJourneyGetsYouMarker() throws {
        let friend = try item("a", user: "A")
        let own = Flight(flightNumber: "GQ 21", date: ISO8601DateFormatter().date(from: "2026-09-18T08:10:00Z")!)
        own.departureIATA = "JSY"; own.arrivalIATA = "ATH"
        XCTAssertEqual(FriendFlightGroup.group([friend], myFlights: [own])[0].myFlightID, own.id)
        own.scheduledDeparture.addTimeInterval(86400)
        XCTAssertNil(FriendFlightGroup.group([friend], myFlights: [own])[0].myFlightID)
    }

    func testMissingIdentityDoesNotCombineUnrelatedFlights() throws {
        let a = try item("a", user: "A", departure: "unknown")
        let b = try item("b", user: "B", departure: "unknown")
        XCTAssertEqual(FriendFlightGroup.group([a, b]).count, 2)
    }
}
