import SwiftUI
import MapKit

/// 3D interactive globe using MapKit — realistic satellite imagery with flight route arcs.
struct GlobeView: View {
    let flights: [Flight]

    var body: some View {
        Map {
            ForEach(flights) { flight in
                if flight.departureLat != 0 && flight.arrivalLat != 0 {
                    MapPolyline(coordinates: [
                        CLLocationCoordinate2D(latitude: flight.departureLat, longitude: flight.departureLon),
                        CLLocationCoordinate2D(latitude: flight.arrivalLat, longitude: flight.arrivalLon)
                    ])
                    .stroke(Color(red: 0.4, green: 0.7, blue: 1.0).opacity(0.8), lineWidth: 2)

                    Annotation("", coordinate: CLLocationCoordinate2D(latitude: flight.departureLat, longitude: flight.departureLon)) {
                        Circle().fill(.white).frame(width: 6, height: 6)
                    }

                    Annotation("", coordinate: CLLocationCoordinate2D(latitude: flight.arrivalLat, longitude: flight.arrivalLon)) {
                        Circle().fill(.white).frame(width: 6, height: 6)
                    }

                    if flight.isActive, let lat = flight.liveLat, let lon = flight.liveLon {
                        Annotation("", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)) {
                            Image(systemName: "airplane.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.white, Color(red: 0.055, green: 0.647, blue: 0.914))
                                .rotationEffect(.degrees(flight.liveHeading ?? 0))
                        }
                    }
                }
            }
        }
        .mapStyle(.imagery(elevation: .realistic))
        .mapControlVisibility(.hidden)
    }
}
