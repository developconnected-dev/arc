import SwiftUI
import MapKit

@MainActor
@Observable
final class MapController {
    var position: MapCameraPosition = .automatic
    var style: MapStyleKind = .standard

    enum MapStyleKind { case standard, hybrid }

    /// Frame the camera to fit all given flights' routes.
    func fitAll(_ flights: [Flight], padding: Double = 1.4) {
        var coords: [CLLocationCoordinate2D] = []
        for f in flights where f.departureLat != 0 && f.arrivalLat != 0 {
            coords.append(.init(latitude: f.departureLat, longitude: f.departureLon))
            coords.append(.init(latitude: f.arrivalLat, longitude: f.arrivalLon))
        }
        if let region = GeoMath.region(fitting: coords, paddingFactor: padding) {
            withAnimation(.easeInOut(duration: 0.6)) { position = .region(region) }
        } else {
            position = .automatic
        }
    }

    /// Frame the camera on a single flight's route.
    func focus(on flight: Flight) {
        let coords = GeoMath.greatCircle(
            from: .init(latitude: flight.departureLat, longitude: flight.departureLon),
            to: .init(latitude: flight.arrivalLat, longitude: flight.arrivalLon))
        if let region = GeoMath.region(fitting: coords, paddingFactor: 1.8) {
            withAnimation(.easeInOut(duration: 0.6)) { position = .region(region) }
        }
    }

    /// Follow a live plane position (used in-flight).
    func follow(lat: Double, lon: Double) {
        withAnimation(.easeInOut(duration: 0.8)) {
            position = .region(MKCoordinateRegion(
                center: .init(latitude: lat, longitude: lon),
                span: MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 30)))
        }
    }
}
