import XCTest
@testable import Arc

@MainActor
final class SupabaseSyncTests: XCTestCase {
    private func makeFlight() -> Flight {
        let dep = Date(timeIntervalSince1970: 1_800_000_000)
        let f = Flight(flightNumber: "LX1413", date: dep)
        f.airline = "Swiss"
        f.departureIATA = "BEG"; f.arrivalIATA = "ZRH"
        f.departureCity = "Belgrade"; f.arrivalCity = "Zurich"
        f.scheduledArrival = dep.addingTimeInterval(2 * 3600)
        f.statusRaw = "scheduled"
        f.bookingCode = "ABC123"
        f.seat = "14A"
        return f
    }

    func testBodyIncludesCoreIdentityFields() {
        let f = makeFlight()
        let body = ArcSupabase.userFlightBody(f, userId: "user-abc")
        XCTAssertEqual(body["id"] as? String, f.id.uuidString)
        XCTAssertEqual(body["user_id"] as? String, "user-abc")
        XCTAssertEqual(body["flight_number"] as? String, "LX1413")
        XCTAssertEqual(body["departure_iata"] as? String, "BEG")
        XCTAssertEqual(body["arrival_iata"] as? String, "ZRH")
    }

    func testBodyIncludesUserEnteredTripDetails() {
        let body = ArcSupabase.userFlightBody(makeFlight(), userId: "user-abc")
        XCTAssertEqual(body["booking_code"] as? String, "ABC123")
        XCTAssertEqual(body["seat"] as? String, "14A")
    }

    /// Regression: a nil optional Date must serialize to something PostgREST
    /// accepts (NSNull, i.e. JSON null) — `as Any` on a nil Date would instead
    /// produce an Optional<Date>.none wrapped in Any, which JSONSerialization
    /// cannot encode and throws on.
    func testBodyEncodesNilOptionalDatesAsValidJSON() {
        let body = ArcSupabase.userFlightBody(makeFlight(), userId: "user-abc")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }

    func testBodyStatusMatchesFlightStatusRaw() {
        let f = makeFlight()
        f.statusRaw = "landed"
        let body = ArcSupabase.userFlightBody(f, userId: "user-abc")
        XCTAssertEqual(body["status"] as? String, "landed")
    }
}
