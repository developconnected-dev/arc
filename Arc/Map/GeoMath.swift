import Foundation
import CoreLocation
import MapKit

enum GeoMath {
    /// Samples `samples` intermediate points along the great circle from a to b
    /// (inclusive of both endpoints) so a MapPolyline renders a curved arc.
    static func greatCircle(from a: CLLocationCoordinate2D,
                            to b: CLLocationCoordinate2D,
                            samples: Int = 64) -> [CLLocationCoordinate2D] {
        let n = max(2, samples)
        let lat1 = a.latitude * .pi / 180, lon1 = a.longitude * .pi / 180
        let lat2 = b.latitude * .pi / 180, lon2 = b.longitude * .pi / 180
        let dLat = lat2 - lat1, dLon = lon2 - lon1
        let hav = sin(dLat/2)*sin(dLat/2) + cos(lat1)*cos(lat2)*sin(dLon/2)*sin(dLon/2)
        let d = 2 * asin(min(1, sqrt(hav)))
        guard d > 1e-9 else { return [a, b] }
        var pts: [CLLocationCoordinate2D] = []
        for i in 0...n {
            let f = Double(i) / Double(n)
            let A = sin((1-f)*d) / sin(d)
            let B = sin(f*d) / sin(d)
            let x = A*cos(lat1)*cos(lon1) + B*cos(lat2)*cos(lon2)
            let y = A*cos(lat1)*sin(lon1) + B*cos(lat2)*sin(lon2)
            let z = A*sin(lat1) + B*sin(lat2)
            let lat = atan2(z, sqrt(x*x + y*y))
            let lon = atan2(y, x)
            pts.append(.init(latitude: lat*180/(.pi), longitude: lon*180/(.pi)))
        }
        return pts
    }

    /// A region that fits all given coordinates with padding, clamped to sane spans.
    static func region(fitting coords: [CLLocationCoordinate2D],
                       paddingFactor: Double = 1.4) -> MKCoordinateRegion? {
        guard !coords.isEmpty else { return nil }
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!
        let center = CLLocationCoordinate2D(latitude: (minLat+maxLat)/2, longitude: (minLon+maxLon)/2)
        let span = MKCoordinateSpan(
            latitudeDelta: max(2, (maxLat-minLat) * paddingFactor),
            longitudeDelta: max(2, (maxLon-minLon) * paddingFactor)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}
