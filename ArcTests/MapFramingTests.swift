import XCTest
import MapKit
@testable import Arc

@MainActor
final class MapFramingTests: XCTestCase {
    private let athMuc = [CLLocationCoordinate2D(latitude: 37.94, longitude: 23.94),
                          CLLocationCoordinate2D(latitude: 48.35, longitude: 11.79)]

    private func effectiveLat(_ fitted: MKCoordinateRegion) -> Double {
        let latScale = max(0.2, cos(fitted.center.latitude * .pi / 180))
        return min(70, max(fitted.span.latitudeDelta, fitted.span.longitudeDelta * 2.16 * latScale))
    }

    /// Friends, Passport and every existing caller keep today's framing exactly.
    func testUpperHalfBandIsTheOldFraming() throws {
        let fitted = try XCTUnwrap(GeoMath.region(fitting: athMuc, paddingFactor: 1.25))
        let e = effectiveLat(fitted)
        let region = try XCTUnwrap(MapController.region(fitting: athMuc, band: .upperHalf, padding: 1.25))
        XCTAssertEqual(region.span.latitudeDelta, min(160, e * 2), accuracy: 1e-9)
        XCTAssertEqual(region.center.latitude, fitted.center.latitude - e / 2, accuracy: 1e-9)
    }

    /// The route's centre lands in the middle of the band.
    func testRouteCentresInANarrowBand() throws {
        let band = MapBand(top: 0.125, bottom: 0.42)
        let fitted = try XCTUnwrap(GeoMath.region(fitting: athMuc, paddingFactor: 1.25))
        let region = try XCTUnwrap(MapController.region(fitting: athMuc, band: band, padding: 1.25))
        let screenTop = region.center.latitude + region.span.latitudeDelta / 2
        let fraction = (screenTop - fitted.center.latitude) / region.span.latitudeDelta
        XCTAssertEqual(fraction, (band.top + band.bottom) / 2, accuracy: 1e-9)
    }

    /// A band thinner than a fifth of the screen doesn't zoom any further —
    /// the floor in `region(fitting:band:padding:)` caps the divisor there.
    func testThinBandZoomsNoFurtherThanAFifthOfTheScreen() throws {
        let thin = try XCTUnwrap(MapController.region(fitting: athMuc, band: MapBand(top: 0.4, bottom: 0.45), padding: 1.25))
        let atFloor = try XCTUnwrap(MapController.region(fitting: athMuc, band: MapBand(top: 0.4, bottom: 0.6), padding: 1.25))
        XCTAssertEqual(thin.span.latitudeDelta, atFloor.span.latitudeDelta, accuracy: 1e-9)
    }

    /// Past the clamps, placement is best-effort — like the 160° cap on span.
    /// This pins that a long-haul route into an off-centre band never
    /// produces an invalid region (an out-of-range latitude, a NaN, or an
    /// infinite span), even though it may not land exactly mid-band.
    func testLongHaulIntoAnOffCentreBandStaysWithinTheClamps() throws {
        let zrhJfk = [CLLocationCoordinate2D(latitude: 47.46, longitude: 8.55),
                      CLLocationCoordinate2D(latitude: 40.64, longitude: -73.78)]
        let region = try XCTUnwrap(MapController.region(fitting: zrhJfk, band: MapBand(top: 0.6, bottom: 0.75), padding: 1.25))
        XCTAssertLessThanOrEqual(region.span.latitudeDelta, 160)
        XCTAssertTrue((-75...75).contains(region.center.latitude))
        XCTAssertTrue(region.span.latitudeDelta.isFinite)
        XCTAssertTrue(region.center.latitude.isFinite)
    }
}
