import XCTest
import CoreLocation
@testable import Arc

/// The plane used to need a live ADS-B fix, so an airborne flight showed no
/// aircraft at all whenever OpenSky had nothing for it — which is often, and
/// always when offline. These cover the clock-derived fallback.
final class PlanePositionTests: XCTestCase {
    private let zrh = CLLocationCoordinate2D(latitude: 47.46, longitude: 8.55)
    private let jfk = CLLocationCoordinate2D(latitude: 40.64, longitude: -73.78)

    private var route: [CLLocationCoordinate2D] { GeoMath.greatCircle(from: zrh, to: jfk) }

    func testStartAndEndSitOnTheAirports() {
        let start = GeoMath.position(along: route, progress: 0)
        let end = GeoMath.position(along: route, progress: 1)
        XCTAssertEqual(GeoMath.distanceKm(start!.coordinate, zrh), 0, accuracy: 1)
        XCTAssertEqual(GeoMath.distanceKm(end!.coordinate, jfk), 0, accuracy: 1)
    }

    func testHalfwayIsRoughlyMidRoute() {
        let mid = GeoMath.position(along: route, progress: 0.5)!.coordinate
        let total = GeoMath.distanceKm(zrh, jfk)
        let fromDep = GeoMath.distanceKm(zrh, mid)
        XCTAssertEqual(fromDep, total / 2, accuracy: total * 0.05)
    }

    func testProgressAdvancesAlongTheRoute() {
        let quarter = GeoMath.position(along: route, progress: 0.25)!.coordinate
        let threeQuarters = GeoMath.position(along: route, progress: 0.75)!.coordinate
        XCTAssertLessThan(GeoMath.distanceKm(zrh, quarter),
                          GeoMath.distanceKm(zrh, threeQuarters))
    }

    func testOutOfRangeProgressIsClamped() {
        XCTAssertEqual(GeoMath.distanceKm(GeoMath.position(along: route, progress: -3)!.coordinate, zrh),
                       0, accuracy: 1)
        XCTAssertEqual(GeoMath.distanceKm(GeoMath.position(along: route, progress: 9)!.coordinate, jfk),
                       0, accuracy: 1)
    }

    func testDegenerateRouteYieldsNothing() {
        XCTAssertNil(GeoMath.position(along: [], progress: 0.5))
        XCTAssertNil(GeoMath.position(along: [zrh], progress: 0.5))
    }

    /// Zurich to New York heads broadly north-west, and the icon must point
    /// along the arc rather than at a fixed angle.
    func testHeadingPointsAlongTheRoute() {
        let heading = GeoMath.position(along: route, progress: 0.1)!.heading
        XCTAssertTrue((270...340).contains(heading), "expected north-westerly, got \(heading)")
    }

    func testBearingCardinals() {
        let origin = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        XCTAssertEqual(GeoMath.bearing(from: origin, to: .init(latitude: 10, longitude: 0)), 0, accuracy: 1)
        XCTAssertEqual(GeoMath.bearing(from: origin, to: .init(latitude: 0, longitude: 10)), 90, accuracy: 1)
        XCTAssertEqual(GeoMath.bearing(from: origin, to: .init(latitude: -10, longitude: 0)), 180, accuracy: 1)
    }
}
