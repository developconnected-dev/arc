import XCTest
import CoreLocation
import MapKit
@testable import Arc

/// The camera used to be parked on the gate, so at a big airport the aircraft
/// taxied off screen and the user watched an empty apron. These check that both
/// stay in frame and that the view tightens as the gap closes.
@MainActor
final class TaxiCameraTests: XCTestCase {
    // Zurich: a gate, a runway threshold ~3km away, and a point near the gate.
    private let gate = CLLocationCoordinate2D(latitude: 47.4510, longitude: 8.5640)
    private let farRunway = CLLocationCoordinate2D(latitude: 47.4750, longitude: 8.5400)
    private let almostThere = CLLocationCoordinate2D(latitude: 47.4515, longitude: 8.5645)

    private func region(plane: CLLocationCoordinate2D,
                        gate: CLLocationCoordinate2D?) -> MKCoordinateRegion? {
        let controller = MapController()
        controller.followTaxi(plane: plane, gate: gate)
        return controller.position.region
    }

    func testBothPlaneAndGateStayInFrame() {
        guard let r = region(plane: farRunway, gate: gate) else { return XCTFail("no region") }
        let halfLat = r.span.latitudeDelta / 2, halfLon = r.span.longitudeDelta / 2
        for point in [farRunway, gate] {
            XCTAssertLessThanOrEqual(abs(point.latitude - r.center.latitude), halfLat + 0.02,
                                     "point outside the framed region")
            XCTAssertLessThanOrEqual(abs(point.longitude - r.center.longitude), halfLon + 0.02)
        }
    }

    /// The whole point: as the plane closes on the gate the camera tightens.
    func testViewTightensAsThePlaneArrives() {
        guard let far = region(plane: farRunway, gate: gate),
              let near = region(plane: almostThere, gate: gate) else { return XCTFail("no region") }
        XCTAssertLessThan(near.span.latitudeDelta, far.span.latitudeDelta)
    }

    /// Two points metres apart must not zoom to the length of an aircraft.
    func testKeepsAGateSizedFloor() {
        guard let r = region(plane: almostThere, gate: gate) else { return XCTFail("no region") }
        XCTAssertGreaterThanOrEqual(r.span.latitudeDelta, 0.0045)
        XCTAssertGreaterThanOrEqual(r.span.longitudeDelta, 0.0045)
    }

    /// No gate matched yet — still follow the aircraft rather than doing nothing.
    func testWorksWithNoGate() {
        guard let r = region(plane: farRunway, gate: nil) else { return XCTFail("no region") }
        XCTAssertGreaterThanOrEqual(r.span.latitudeDelta, 0.0045)
    }

    /// The detail sheet owns the bottom half, so the framing sits above it.
    func testFramingIsShiftedAboveTheSheet() {
        guard let r = region(plane: almostThere, gate: gate) else { return XCTFail("no region") }
        XCTAssertLessThan(r.center.latitude, min(almostThere.latitude, gate.latitude))
    }

    /// The offset must come from the DISPLAYED height, not `latitudeDelta`.
    ///
    /// In portrait MapKit stretches the latitude span to match the longitude
    /// one, so when a plane and its gate are far apart east-west the real
    /// displayed height is many times `latitudeDelta`. Offsetting by a fraction
    /// of `latitudeDelta` then shifts almost nothing, and the aircraft sat
    /// behind the sheet — which is exactly what happened live, and what the
    /// weaker assertion above sailed straight past.
    func testOffsetScalesWithTheWiderSpan() {
        // Same latitude, far apart in longitude: latitudeDelta collapses to the
        // floor while longitude dominates what's actually shown.
        let west = CLLocationCoordinate2D(latitude: 47.4500, longitude: 8.5000)
        let east = CLLocationCoordinate2D(latitude: 47.4500, longitude: 8.6200)
        guard let r = region(plane: west, gate: east) else { return XCTFail("no region") }

        // Offsetting by 0.25 * latitudeDelta (the floor, 0.0045) would move the
        // centre ~0.001° — indistinguishable from no shift at all.
        XCTAssertLessThan(r.center.latitude, 47.4500 - 0.02,
                          "offset ignored the longitude-driven displayed height")
    }
}
