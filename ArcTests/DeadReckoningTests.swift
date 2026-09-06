import XCTest
import CoreLocation
@testable import Arc

/// Where the aircraft is, on one rule: from the last place it was really
/// seen, along the route ahead, paced so it reaches the airport exactly when
/// the arrival countdown ends. The line, the dotted remainder and the plane
/// glyph all read this, so they can never detach from each other.
@MainActor
final class DeadReckoningTests: XCTestCase {
    private let zrh = CLLocationCoordinate2D(latitude: 47.4647, longitude: 8.5492)
    private let jfk = CLLocationCoordinate2D(latitude: 40.6413, longitude: -73.7781)
    private let midAtlantic = CLLocationCoordinate2D(latitude: 55.0, longitude: -25.0)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func km(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        GeoMath.distanceKm(a, b)
    }

    private func sighting(_ coordinate: CLLocationCoordinate2D, ago: TimeInterval,
                          heading: Double? = nil) -> DeadReckoning.Anchor {
        .init(coordinate: coordinate, at: now.addingTimeInterval(-ago), heading: heading, isSighting: true)
    }

    // MARK: - The rule

    /// A fresh fix is where the plane is — and it keeps moving from there,
    /// because a five-minute-old fix at cruise is already seventy kilometres
    /// behind the aircraft.
    func testAFreshFixAnchorsThePlaneAndItGlidesOnFromIt() throws {
        let remaining = GeoMath.greatCircle(from: midAtlantic, to: jfk)
        let plane = try XCTUnwrap(DeadReckoning.position(
            anchor: sighting(midAtlantic, ago: 5 * 60), remaining: remaining,
            eta: now.addingTimeInterval(3 * 3600), now: now))
        XCTAssertTrue(plane.isLive)
        XCTAssertEqual(plane.fraction, 5.0 / 185.0, accuracy: 0.001)
        // A little way along the route ahead, not sitting on the fix.
        let total = km(midAtlantic, jfk)
        XCTAssertGreaterThan(km(midAtlantic, plane.coordinate), 0.02 * total)
        XCTAssertLessThan(km(midAtlantic, plane.coordinate), 0.04 * total)
    }

    /// Fifteen minutes is where a fix stops being drawn as "this is real".
    /// It is NOT where the plane jumps: the estimate one second either side
    /// of the boundary is the same place.
    func testTheEstimateIsContinuousAcrossTheFreshnessBoundary() throws {
        let remaining = GeoMath.greatCircle(from: midAtlantic, to: jfk)
        let eta = now.addingTimeInterval(3 * 3600)
        let justFresh = try XCTUnwrap(DeadReckoning.position(
            anchor: sighting(midAtlantic, ago: 15 * 60 - 1), remaining: remaining, eta: eta, now: now))
        let justStale = try XCTUnwrap(DeadReckoning.position(
            anchor: sighting(midAtlantic, ago: 15 * 60 + 1), remaining: remaining, eta: eta, now: now))
        XCTAssertTrue(justFresh.isLive)
        XCTAssertFalse(justStale.isLive)
        XCTAssertLessThan(km(justFresh.coordinate, justStale.coordinate), 1)
    }

    /// Never seen at all: the anchor is the departure airport at the moment
    /// it left, and the estimate is the clock along the whole route.
    func testANeverSeenAircraftIsReckonedFromTheGate() throws {
        let departed = DeadReckoning.Anchor(coordinate: zrh, at: now.addingTimeInterval(-4 * 3600),
                                            heading: nil, isSighting: false)
        let plane = try XCTUnwrap(DeadReckoning.position(
            anchor: departed, remaining: GeoMath.greatCircle(from: zrh, to: jfk),
            eta: now.addingTimeInterval(4 * 3600), now: now))
        XCTAssertFalse(plane.isLive)
        XCTAssertEqual(plane.fraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(km(zrh, plane.coordinate), km(plane.coordinate, jfk), accuracy: 0.02 * km(zrh, jfk))
    }

    /// The plane reaches the airport dot exactly when the countdown ends,
    /// and holds there if the flight is still up after its ETA.
    func testThePlaneArrivesWhenTheCountdownEndsAndHoldsThere() throws {
        let remaining = GeoMath.greatCircle(from: midAtlantic, to: jfk)
        let anchor = sighting(midAtlantic, ago: 3 * 3600)
        let onTime = try XCTUnwrap(DeadReckoning.position(anchor: anchor, remaining: remaining, eta: now, now: now))
        XCTAssertEqual(onTime.fraction, 1, accuracy: 0.0001)
        XCTAssertLessThan(km(onTime.coordinate, jfk), 1)
        let overdue = try XCTUnwrap(DeadReckoning.position(
            anchor: anchor, remaining: remaining, eta: now.addingTimeInterval(-600), now: now))
        XCTAssertLessThan(km(overdue.coordinate, jfk), 1)
    }

    /// A fix stamped later than the clock — skew, a provider's rounding —
    /// holds the plane on the fix rather than reckoning backwards.
    func testAFixNewerThanTheClockHoldsThePlaneOnIt() throws {
        let plane = try XCTUnwrap(DeadReckoning.position(
            anchor: sighting(midAtlantic, ago: -90), remaining: GeoMath.greatCircle(from: midAtlantic, to: jfk),
            eta: now.addingTimeInterval(3600), now: now))
        XCTAssertEqual(plane.fraction, 0, accuracy: 0.0001)
        XCTAssertLessThan(km(plane.coordinate, midAtlantic), 0.001)
    }

    /// The transponder's heading is used while the fix is fresh; once the
    /// plane is reckoned along the route, it points along the route.
    func testHeadingComesFromTheFixWhileFreshThenFromTheRoute() throws {
        let remaining = GeoMath.greatCircle(from: midAtlantic, to: jfk)
        let eta = now.addingTimeInterval(3 * 3600)
        let fresh = try XCTUnwrap(DeadReckoning.position(
            anchor: sighting(midAtlantic, ago: 60, heading: 123), remaining: remaining, eta: eta, now: now))
        XCTAssertEqual(fresh.heading, 123, accuracy: 0.001)
        let stale = try XCTUnwrap(DeadReckoning.position(
            anchor: sighting(midAtlantic, ago: 40 * 60, heading: 123), remaining: remaining, eta: eta, now: now))
        let alongRoute = GeoMath.bearing(from: remaining[10], to: remaining[11])
        XCTAssertEqual(stale.heading, alongRoute, accuracy: 15)
    }

    func testNothingAheadYieldsNothing() {
        XCTAssertNil(DeadReckoning.position(anchor: sighting(midAtlantic, ago: 60), remaining: [midAtlantic],
                                            eta: now.addingTimeInterval(3600), now: now))
    }

    // MARK: - On a flight

    private func activeFlight() -> Flight {
        let flight = Flight(flightNumber: "LX14", date: now)
        flight.mode = .air
        flight.scheduledDeparture = now.addingTimeInterval(-2 * 3600)
        flight.actualDeparture = now.addingTimeInterval(-2 * 3600)
        flight.scheduledArrival = now.addingTimeInterval(6 * 3600)
        flight.estimatedArrival = now.addingTimeInterval(5 * 3600)
        flight.departureLat = zrh.latitude; flight.departureLon = zrh.longitude
        flight.arrivalLat = jfk.latitude; flight.arrivalLon = jfk.longitude
        return flight
    }

    /// The anchor is whichever the aircraft was seen at LAST: a live fix
    /// older than the newest breadcrumb loses to it, and vice versa.
    func testTheLastSightingIsTheNewerOfFixAndBreadcrumb() throws {
        let flight = activeFlight()
        XCTAssertNil(flight.lastSighting)

        flight.trackPoints = [.init(lat: 50, lon: -10, timestamp: now.addingTimeInterval(-1800), altitude: nil)]
        var anchor = try XCTUnwrap(flight.lastSighting)
        XCTAssertEqual(anchor.coordinate.longitude, -10)
        XCTAssertTrue(anchor.isSighting)

        flight.liveLat = 52; flight.liveLon = -15; flight.liveUpdatedAt = now.addingTimeInterval(-600)
        anchor = try XCTUnwrap(flight.lastSighting)
        XCTAssertEqual(anchor.coordinate.longitude, -15)

        flight.trackPoints = [.init(lat: 53, lon: -18, timestamp: now.addingTimeInterval(-60), altitude: nil)]
        anchor = try XCTUnwrap(flight.lastSighting)
        XCTAssertEqual(anchor.coordinate.longitude, -18)
    }

    /// The whole point: the glyph lies ON the dotted remainder that starts
    /// at the last sighting, at the fraction the clock has paced it to — so
    /// the solid line, the dotted line and the plane meet by construction.
    func testTheGlyphLiesOnTheRemainderFromTheLastSighting() throws {
        let flight = activeFlight()
        flight.liveLat = midAtlantic.latitude; flight.liveLon = midAtlantic.longitude
        flight.liveUpdatedAt = now.addingTimeInterval(-30 * 60)

        let anchor = try XCTUnwrap(flight.lastSighting)
        let remaining = flight.remainingPath(from: anchor.coordinate)
        let plane = try XCTUnwrap(flight.planePosition(now: now))
        XCTAssertFalse(plane.isLive)
        // 30 min into the 5h30 between the fix and the ETA.
        XCTAssertEqual(plane.fraction, 30.0 / 330.0, accuracy: 0.001)
        XCTAssertLessThan(km(remaining.first!, midAtlantic), 0.001)
        XCTAssertLessThan(km(remaining.last!, jfk), 0.001)
        let nearest = remaining.map { km($0, plane.coordinate) }.min()!
        XCTAssertLessThan(nearest, 60, "the plane sits beside its own dotted line")
    }

    /// Never seen: reckoned from the gate along the planned route.
    func testAFlightNeverSeenIsReckonedFromItsDepartureAirport() throws {
        let plane = try XCTUnwrap(activeFlight().planePosition(now: now))
        XCTAssertFalse(plane.isLive)
        XCTAssertEqual(plane.fraction, 2.0 / 7.0, accuracy: 0.001)
    }

    /// A train reckons along its RAILS from the last sighting, not along an
    /// arc between it and the terminus.
    func testARailLegReckonsAlongItsRailsFromTheSighting() throws {
        let flight = activeFlight()
        flight.mode = .rail
        flight.routePathData = try JSONEncoder().encode([[47.0, 8.0], [47.5, 8.5], [48.0, 9.0], [48.5, 9.5], [49.0, 10.0]])
        flight.departureLat = 47; flight.departureLon = 8
        flight.arrivalLat = 49; flight.arrivalLon = 10
        let nearSecond = CLLocationCoordinate2D(latitude: 47.52, longitude: 8.48)
        let remaining = flight.remainingPath(from: nearSecond)
        XCTAssertEqual(remaining.count, 4, "the sighting, then the rails still ahead of it")
        XCTAssertEqual(remaining.first!.latitude, 47.52, accuracy: 0.0001)
        XCTAssertEqual(remaining[1].latitude, 48.0, accuracy: 0.0001)
        XCTAssertEqual(remaining.last!.latitude, 49.0, accuracy: 0.0001)
    }
}
