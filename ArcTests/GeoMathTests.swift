import XCTest
import CoreLocation
@testable import Arc

final class GeoMathTests: XCTestCase {
    func testGreatCircleEndpointsPreserved() {
        let a = CLLocationCoordinate2D(latitude: 47.46, longitude: 8.55)   // ZRH
        let b = CLLocationCoordinate2D(latitude: 40.64, longitude: -73.78) // JFK
        let pts = GeoMath.greatCircle(from: a, to: b, samples: 32)
        XCTAssertEqual(pts.count, 33)
        XCTAssertEqual(pts.first!.latitude, a.latitude, accuracy: 0.01)
        XCTAssertEqual(pts.last!.longitude, b.longitude, accuracy: 0.01)
    }

    func testGreatCircleBowsNorthOnTransatlantic() {
        let a = CLLocationCoordinate2D(latitude: 47.46, longitude: 8.55)
        let b = CLLocationCoordinate2D(latitude: 40.64, longitude: -73.78)
        let pts = GeoMath.greatCircle(from: a, to: b, samples: 32)
        let mid = pts[16]
        // The arc midpoint sits north of the straight-line latitude average (~44).
        XCTAssertGreaterThan(mid.latitude, 47.0)
    }

    func testRegionFitsCoordinates() {
        let region = GeoMath.region(fitting: [
            .init(latitude: 47.46, longitude: 8.55),
            .init(latitude: 40.64, longitude: -73.78),
        ])!
        XCTAssertEqual(region.center.latitude, 44.05, accuracy: 0.5)
        XCTAssertGreaterThan(region.span.longitudeDelta, 80)
    }

    func testRegionNilForEmpty() {
        XCTAssertNil(GeoMath.region(fitting: []))
    }
}
