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

// MARK: - The cloud mirror has to say which KIND of journey it is

/// Two server-side guards ask `user_flights.mode` whether a row is a flight,
/// and neither could ever get a truthful answer: the column exists, is
/// `not null default 'air'`, and this body never wrote it. So every train and
/// every sailing arrived in the mirror indistinguishable from a flight.
///
/// What that costs, in the two places that ask:
///
///  * `pushStarts` refuses to push-to-start anything but air, because a Live
///    Activity for a train would put plane iconography and gate copy on a lock
///    screen. Reading 'air' for a train, it started one anyway.
///  * `watchUpcoming` skips non-air rows because AeroDataBox only answers for
///    flights. Reading 'air' for a train, it spent a budget-guarded provider
///    call on a guaranteed miss, every watch interval, for every train.
///
/// The mode reaches `shared_flights` — a friend sees the right journey — which
/// is exactly why this stayed invisible: the surface people look at was right.
@MainActor
final class UserFlightModeTests: XCTestCase {
    private func trip(_ mode: TripMode, _ number: String) -> Flight {
        let f = Flight(flightNumber: number, date: Date(timeIntervalSince1970: 1_800_000_000))
        f.mode = mode
        return f
    }

    func testAFlightIsMirroredAsAir() {
        let body = ArcSupabase.userFlightBody(trip(.air, "LX1413"), userId: "u")
        XCTAssertEqual(body["mode"] as? String, "air")
    }

    /// THE regression: without this the row defaults to 'air' and both guards
    /// silently pass a train through.
    func testATrainIsMirroredAsRail() {
        let body = ArcSupabase.userFlightBody(trip(.rail, "ICE 574"), userId: "u")
        XCTAssertEqual(body["mode"] as? String, "rail")
    }

    func testAFerryIsMirroredAsSea() {
        let body = ArcSupabase.userFlightBody(trip(.sea, "BLUE STAR 2"), userId: "u")
        XCTAssertEqual(body["mode"] as? String, "sea")
    }

    /// The value has to be one the column's own CHECK constraint admits, or
    /// the whole upsert 400s and the flight never reaches the cloud at all.
    func testTheModeIsOneThePostgresConstraintAccepts() {
        for mode in [TripMode.air, .rail, .sea] {
            let value = ArcSupabase.userFlightBody(trip(mode, "X1"), userId: "u")["mode"] as? String
            XCTAssertTrue(["air", "rail", "sea"].contains(value ?? ""), "mode '\(value ?? "nil")' fails the check")
        }
    }
}
