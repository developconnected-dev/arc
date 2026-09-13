import XCTest
@testable import Arc

/// The invite payload is a journey with the sender's booking stripped out; the
/// recipient's copy must come back the same journey. Round-trips go through
/// real JSON bytes — what PostgREST stores and returns — not Swift values.
@MainActor
final class TripInviteTests: XCTestCase {
    private func sampleFerry() -> Flight {
        let dep = Date(timeIntervalSince1970: 1_790_000_000)
        let f = Flight(flightNumber: "BLUE STAR DELOS", date: dep)
        f.mode = .sea
        f.dataTier = .scheduled
        f.airline = "Blue Star Ferries"
        f.departureIATA = "PIR"; f.arrivalIATA = "THI"
        f.departureStopID = "Piraeus"; f.arrivalStopID = "Santorini"
        f.departureTZID = "Europe/Athens"; f.arrivalTZID = "Europe/Athens"
        f.departureCity = "Piraeus"; f.arrivalCity = "Santorini"
        f.departureLat = 37.94; f.departureLon = 23.64
        f.arrivalLat = 36.42; f.arrivalLon = 25.43
        f.scheduledDeparture = dep
        f.scheduledArrival = dep.addingTimeInterval(8 * 3600)
        f.statusRaw = "scheduled"
        f.vesselName = "BLUE STAR DELOS"; f.vesselMMSI = "241087000"
        f.operatorLogoURL = "https://example.com/bsf.png"
        f.disruptionNote = "Departs from gate E2 today"
        f.bookingURL = "https://example.com/booking"
        f.routePathData = try? JSONEncoder().encode([[37.94, 23.64], [37.5, 24.2], [36.9, 25.0], [36.42, 25.43]])
        // Private — must NOT cross.
        f.bookingCode = "ABC123"; f.seat = "12A"; f.notes = "window please"
        f.sharedWithIds = ["someone"]
        return f
    }

    /// Two legs of one journey, invited separately and accepted separately,
    /// must still read as the connection they are on the recipient's list —
    /// the sender's list draws the layover spine between them, and the
    /// recipient's must draw the same one.
    func testConnectingLegsStayAConnectionAfterTheRoundTrip() throws {
        let dep = Date.now.addingTimeInterval(3 * 24 * 3600)
        func leg(_ number: String, from: String, to: String, dep: Date, minutes: Double) -> Flight {
            let f = Flight(flightNumber: number, date: dep)
            f.departureIATA = from; f.arrivalIATA = to
            f.scheduledDeparture = dep
            f.scheduledArrival = dep.addingTimeInterval(minutes * 60)
            f.statusRaw = "scheduled"
            return f
        }
        let first = leg("GQ21", from: "JSY", to: "ATH", dep: dep, minutes: 45)
        let second = leg("LH1751", from: "ATH", to: "MUC", dep: dep.addingTimeInterval(105 * 60), minutes: 165)
        XCTAssertNotNil(ConnectionPlanner.detectConnection(from: [first, second]), "the sender's own list sees the connection")

        let copies = try [first, second].map { try TripInvitePayload.decode(TripInvitePayload.body(for: $0)).materialize() }
        let pair = ConnectionPlanner.detectConnection(from: copies)
        XCTAssertNotNil(pair, "the recipient's copies must connect too")
        XCTAssertEqual(pair?.inbound.flightNumber, "GQ21")
        XCTAssertEqual(pair?.outbound.flightNumber, "LH1751")
    }

    func testRoundTripPreservesTheJourney() throws {
        let original = sampleFerry()
        let body = TripInvitePayload.body(for: original)
        let payload = try TripInvitePayload.decode(body)
        let copy = payload.materialize()

        XCTAssertEqual(copy.mode, .sea)
        XCTAssertEqual(copy.dataTier, .scheduled)
        XCTAssertEqual(copy.flightNumber, "BLUE STAR DELOS")
        XCTAssertEqual(copy.airline, "Blue Star Ferries")
        XCTAssertEqual(copy.departureIATA, "PIR"); XCTAssertEqual(copy.arrivalIATA, "THI")
        XCTAssertEqual(copy.departureStopID, "Piraeus"); XCTAssertEqual(copy.arrivalStopID, "Santorini")
        XCTAssertEqual(copy.departureTZID, "Europe/Athens")
        XCTAssertEqual(copy.departureCity, "Piraeus"); XCTAssertEqual(copy.arrivalCity, "Santorini")
        XCTAssertEqual(copy.departureLat, 37.94, accuracy: 1e-9)
        XCTAssertEqual(copy.arrivalLon, 25.43, accuracy: 1e-9)
        XCTAssertEqual(copy.scheduledDeparture.timeIntervalSince1970, original.scheduledDeparture.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(copy.scheduledArrival.timeIntervalSince1970, original.scheduledArrival.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(copy.vesselName, "BLUE STAR DELOS"); XCTAssertEqual(copy.vesselMMSI, "241087000")
        XCTAssertEqual(copy.operatorLogoURL, "https://example.com/bsf.png")
        XCTAssertEqual(copy.disruptionNote, "Departs from gate E2 today")
        XCTAssertEqual(copy.bookingURL, "https://example.com/booking")
        XCTAssertEqual(copy.routePath.count, 4)
        XCTAssertEqual(copy.routePath[1].lon, 24.2, accuracy: 1e-9)
    }

    /// The copy is the recipient's own: fresh identity, no seat, no booking
    /// code, no notes, default audience.
    func testPrivateFieldsNeverCross() throws {
        let original = sampleFerry()
        let body = TripInvitePayload.body(for: original)
        XCTAssertNil(body["booking_code"]); XCTAssertNil(body["seat"]); XCTAssertNil(body["notes"])
        XCTAssertNil(body["id"]); XCTAssertNil(body["user_id"]); XCTAssertNil(body["audience"])

        let copy = try TripInvitePayload.decode(body).materialize()
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertNil(copy.bookingCode); XCTAssertNil(copy.seat); XCTAssertEqual(copy.notes, "")
        XCTAssertNil(copy.sharedWithIds)
    }

    /// A snapshot from a build that knew fewer fields — or more — still decodes.
    func testSparseSnapshotDecodes() throws {
        let sparse: [String: Any] = ["flight_number": "LX14", "scheduled_departure": "2026-09-01T08:00:00Z",
                                     "some_future_field": true]
        let copy = try TripInvitePayload.decode(sparse).materialize()
        XCTAssertEqual(copy.flightNumber, "LX14")
        XCTAssertEqual(copy.mode, .air)
        XCTAssertEqual(copy.dataTier, .live)
        XCTAssertEqual(copy.scheduledArrival.timeIntervalSince(copy.scheduledDeparture), 2 * 3600, accuracy: 1)
    }

    /// A journey already in the past heals to landed, like every other add.
    func testStatusHeals() throws {
        let past: [String: Any] = ["flight_number": "LX14", "scheduled_departure": "2020-01-01T08:00:00Z",
                                   "scheduled_arrival": "2020-01-01T10:00:00Z", "status": "weird"]
        XCTAssertEqual(try TripInvitePayload.decode(past).materialize().status, .landed)
    }

    // MARK: Being on a trip implies seeing it

    func testEveryoneStaysEveryone() {
        XCTAssertNil(TripCompanions.audience(sharedWithIds: nil, travellingWithIds: ["p"]))
    }

    func testExplicitListGainsCompanions() {
        XCTAssertEqual(TripCompanions.audience(sharedWithIds: ["a"], travellingWithIds: ["p", "a"]), ["a", "p"])
    }

    func testPrivateTripOpensToExactlyTheCompanions() {
        XCTAssertEqual(TripCompanions.audience(sharedWithIds: [], travellingWithIds: ["p"]), ["p"])
    }

    func testNoCompanionsChangesNothing() {
        XCTAssertEqual(TripCompanions.audience(sharedWithIds: [], travellingWithIds: []), [])
    }

    // MARK: Journey key

    func testJourneyKeyIgnoresSpacingCaseAndSubMinutePrecision() {
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(FriendsStore.journeyKey("lx 1413", t),
                       FriendsStore.journeyKey("LX1413", t.addingTimeInterval(0.4)))
        XCTAssertNotEqual(FriendsStore.journeyKey("LX1413", t),
                          FriendsStore.journeyKey("LX1413", t.addingTimeInterval(24 * 3600)))
    }
}
