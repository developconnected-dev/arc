import XCTest
import CoreLocation
@testable import Arc

/// The map's body is rebuilt on every state change it observes — the minute
/// tick, a status change, and for one second after an add, sixty times a
/// second while the route draws itself on. Everything that body computes
/// from stored data must therefore be cheap on the second read.
@MainActor
final class MapWorkCacheTests: XCTestCase {

    // MARK: - Decoded geometry on the model

    private func flightWithTrack(_ n: Int) -> Flight {
        let flight = Flight(flightNumber: "TEST1", date: .now)
        flight.trackPoints = (0..<n).map {
            Flight.TrackPoint(lat: 47 + Double($0) * 0.01, lon: 8 + Double($0) * 0.02,
                              timestamp: .now, altitude: 10_000)
        }
        return flight
    }

    /// A stored track is decoded once, not on every read: a thousand reads
    /// cost a small multiple of one honest decode, not a thousand of them.
    func testAStoredTrackIsDecodedOnceNotOnEveryRead() throws {
        let flight = flightWithTrack(600)
        let data = try XCTUnwrap(flight.trackPointsData)

        let started = Date.now
        _ = try JSONDecoder().decode([Flight.TrackPoint].self, from: data)
        let oneDecode = Date.now.timeIntervalSince(started)

        let reads = Date.now
        var total = 0
        for _ in 0..<1000 { total += flight.trackPoints.count }
        let thousandReads = Date.now.timeIntervalSince(reads)

        XCTAssertEqual(total, 600 * 1000)
        XCTAssertLessThan(thousandReads, max(0.02, oneDecode * 50),
                          "1000 reads took \(thousandReads)s against one decode of \(oneDecode)s")
    }

    /// The cache answers for the data it decoded and nothing else: a track
    /// rewritten through the setter, or a blob replaced underneath it by a
    /// sync, is decoded afresh.
    func testARewrittenTrackIsNeverServedStale() throws {
        let flight = flightWithTrack(3)
        XCTAssertEqual(flight.trackPoints.count, 3)

        flight.trackPoints = Array(flight.trackPoints.prefix(1))
        XCTAssertEqual(flight.trackPoints.count, 1)

        let replacement = try JSONEncoder().encode([
            Flight.TrackPoint(lat: 1, lon: 2, timestamp: .now, altitude: nil),
            Flight.TrackPoint(lat: 3, lon: 4, timestamp: .now, altitude: nil),
        ])
        flight.trackPointsData = replacement
        XCTAssertEqual(flight.trackPoints.count, 2)
        XCTAssertEqual(flight.trackPoints.last?.lat, 3)

        flight.trackPointsData = nil
        XCTAssertTrue(flight.trackPoints.isEmpty)
    }

    func testARewrittenRoutePathIsNeverServedStale() throws {
        let flight = Flight(flightNumber: "TEST1", date: .now)
        flight.routePathData = try JSONEncoder().encode([[47.0, 8.0], [48.0, 9.0], [49.0, 10.0]])
        XCTAssertEqual(flight.routePath.count, 3)
        flight.routePathData = try JSONEncoder().encode([[50.0, 11.0], [51.0, 12.0]])
        XCTAssertEqual(flight.routePath.count, 2)
        XCTAssertEqual(flight.routePath.first?.lat, 50)
        flight.routePathData = nil
        XCTAssertTrue(flight.routePath.isEmpty)
    }

    // MARK: - The hazard scan

    private func hazard(_ kind: String, at lat: Double, _ lon: Double) -> FlightAPIClient.WeatherHazard {
        .init(kind: kind, severe: false, base: nil, top: nil, region: nil,
              coords: [.init(lat: lat, lon: lon), .init(lat: lat + 1, lon: lon + 1)])
    }

    private let zrh = CLLocationCoordinate2D(latitude: 47.4647, longitude: 8.5492)
    private let jfk = CLLocationCoordinate2D(latitude: 40.6413, longitude: -73.7781)
    private let ath = CLLocationCoordinate2D(latitude: 37.9364, longitude: 23.9445)

    /// Which advisories sit near which routes is a few hundred thousand
    /// distance checks. It is computed when the advisories or the routes
    /// change, and answered from memory for the same inputs.
    func testTheHazardScanRunsOncePerDistinctInput() {
        var cache = HazardScanCache()
        let all = [hazard("turbulence", at: 47, 8), hazard("icing", at: 38, 24), hazard("thunderstorms", at: -30, 150)]

        let first = cache.hazards(all, routes: [(zrh, jfk)])
        XCTAssertEqual(first.map(\.kind), ["turbulence"])
        XCTAssertEqual(cache.scans, 1)

        let again = cache.hazards(all, routes: [(zrh, jfk)])
        XCTAssertEqual(again.map(\.kind), ["turbulence"])
        XCTAssertEqual(cache.scans, 1, "the same inputs were scanned again")

        let moreRoutes = cache.hazards(all, routes: [(zrh, jfk), (zrh, ath)])
        XCTAssertEqual(Set(moreRoutes.map(\.kind)), ["turbulence", "icing"])
        XCTAssertEqual(cache.scans, 2)

        let fewerHazards = cache.hazards(Array(all.dropFirst()), routes: [(zrh, jfk), (zrh, ath)])
        XCTAssertEqual(fewerHazards.map(\.kind), ["icing"])
        XCTAssertEqual(cache.scans, 3)

        XCTAssertTrue(cache.hazards([], routes: [(zrh, jfk)]).isEmpty)
    }

    // MARK: - A refit skipped during the reveal

    /// The refit that hangs off a flight-list change stands down while a
    /// route draws itself on — but only the change the reveal is FOR is
    /// spent. Anything else that changed the list in that second still
    /// needs its refit once the reveal ends.
    func testOnlyTheRevealsOwnAdditionSpendsTheRefit() {
        let a = UUID(), b = UUID(), added = UUID(), stranger = UUID()
        XCTAssertFalse(RouteReveal.listChangeNeedsRefit(previous: [a, b], current: [a, b, added],
                                                        revealing: [added]),
                       "the add the reveal frames does not need a refit after it")
        XCTAssertFalse(RouteReveal.listChangeNeedsRefit(previous: [a, b], current: [a, b],
                                                        revealing: [added]))
        XCTAssertTrue(RouteReveal.listChangeNeedsRefit(previous: [a, b, added], current: [b, added],
                                                       revealing: [added]),
                      "a trip deleted mid-draw leaves the camera on a route that isn't there")
        XCTAssertTrue(RouteReveal.listChangeNeedsRefit(previous: [a, b], current: [a, b, added, stranger],
                                                       revealing: [added]),
                      "a trip that arrived by another path is not framed by this reveal")
    }
}
