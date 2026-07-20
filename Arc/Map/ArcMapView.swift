import SwiftUI
import MapKit

/// The single shared map. Renders each flight's great-circle route, airport pins,
/// and (for active flights) the live plane. Camera driven by `MapController`.
struct ArcMapView: View {
    let flights: [Flight]
    @Bindable var controller: MapController

    var body: some View {
        Map(position: $controller.position) {
            ForEach(flights) { flight in
                if flight.departureLat != 0 && flight.arrivalLat != 0 {
                    let dep = CLLocationCoordinate2D(latitude: flight.departureLat, longitude: flight.departureLon)
                    let arr = CLLocationCoordinate2D(latitude: flight.arrivalLat, longitude: flight.arrivalLon)

                    MapPolyline(coordinates: GeoMath.greatCircle(from: dep, to: arr))
                        .stroke(ArcTheme.routeLine, style: StrokeStyle(lineWidth: 2, lineCap: .round))

                    Annotation("", coordinate: dep) { endpointDot }
                    Annotation("", coordinate: arr) { endpointDot }

                    if flight.isActive, let lat = flight.liveLat, let lon = flight.liveLon {
                        Annotation("", coordinate: .init(latitude: lat, longitude: lon)) {
                            Image(systemName: "airplane")
                                .font(.system(size: 18, weight: .black))
                                .foregroundStyle(.white)
                                .rotationEffect(.degrees((flight.liveHeading ?? 0) - 90))
                                .shadow(radius: 2)
                        }
                    }
                }
            }
        }
        .mapStyle(controller.style == .hybrid ? .hybrid(elevation: .realistic) : .standard(elevation: .realistic))
        .mapControlVisibility(.hidden)
    }

    private var endpointDot: some View {
        Circle().fill(.white).frame(width: 10, height: 10)
            .overlay(Circle().stroke(ArcTheme.action, lineWidth: 3))
    }
}
