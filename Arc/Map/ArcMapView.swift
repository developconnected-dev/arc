import SwiftUI
import MapKit

/// The single shared map. Renders each flight's great-circle route, airport pins,
/// and (for active flights) the live plane. Camera driven by `MapController`.
struct ArcMapView: View {
    let flights: [Flight]
    @Bindable var controller: MapController

    var body: some View {
        Map(position: $controller.position) {
            if let plane = controller.livePlane {
                Annotation("", coordinate: .init(latitude: plane.lat, longitude: plane.lon)) {
                    Image(systemName: "airplane")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(.orange)
                        .rotationEffect(.degrees(plane.heading - 90))
                        .shadow(color: .black.opacity(0.4), radius: 2)
                }
            }
            if let marker = controller.gateMarker {
                Annotation(marker.label, coordinate: .init(latitude: marker.lat, longitude: marker.lon)) {
                    ZStack {
                        Circle().fill(ArcTheme.action).frame(width: 34, height: 34)
                            .shadow(color: ArcTheme.action.opacity(0.5), radius: 5)
                        Image(systemName: "airplane")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            ForEach(flights) { flight in
                if flight.departureLat != 0 && flight.arrivalLat != 0 {
                    let dep = CLLocationCoordinate2D(latitude: flight.departureLat, longitude: flight.departureLon)
                    let arr = CLLocationCoordinate2D(latitude: flight.arrivalLat, longitude: flight.arrivalLon)
                    let track = flight.trackPoints

                    if flight.isCompleted, track.count >= 2 {
                        // Landed: the real recorded path, airport to airport —
                        // what you actually flew, not a theoretical arc. Past
                        // routes render dark and muted, no glow.
                        let flown = [dep] + track.map {
                            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                        } + [arr]
                        MapPolyline(coordinates: flown)
                            .stroke(ArcTheme.routeLinePast, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    } else if flight.isActive, track.count >= 2 {
                        // We have real recorded positions: draw the path actually
                        // flown (solid, airport → breadcrumbs → current position)
                        // and the projected remainder (dashed great-circle from
                        // current position to the arrival airport) — instead of a
                        // theoretical arc the plane may not be on at all.
                        let current = CLLocationCoordinate2D(
                            latitude: flight.liveLat ?? track[track.count - 1].lat,
                            longitude: flight.liveLon ?? track[track.count - 1].lon)
                        let flown = [dep] + track.map {
                            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                        } + [current]

                        // Active: brightest treatment — glow halo under the
                        // crisp line. (MapPolyline can't take a shadow, so the
                        // glow is a wide low-opacity stroke of the same path.)
                        MapPolyline(coordinates: flown)
                            .stroke(ArcTheme.routeLine.opacity(0.30), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        MapPolyline(coordinates: flown)
                            .stroke(ArcTheme.routeLine, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        MapPolyline(coordinates: GeoMath.greatCircle(from: current, to: arr))
                            .stroke(ArcTheme.routeLine.opacity(0.55),
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 6]))
                    } else if flight.isCompleted {
                        // Past, no recorded track: muted great circle.
                        MapPolyline(coordinates: GeoMath.greatCircle(from: dep, to: arr))
                            .stroke(ArcTheme.routeLinePast, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    } else {
                        // Upcoming (or active without track): bright + glow.
                        let gc = GeoMath.greatCircle(from: dep, to: arr)
                        MapPolyline(coordinates: gc)
                            .stroke(ArcTheme.routeLine.opacity(0.28), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        MapPolyline(coordinates: gc)
                            .stroke(ArcTheme.routeLine, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    }

                    Annotation("", coordinate: dep) { endpointDot(past: flight.isCompleted) }
                    Annotation("", coordinate: arr) { endpointDot(past: flight.isCompleted) }

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
        .overlay(alignment: .topLeading) {
            if controller.gateMarker != nil {
                Button { controller.clearGateMarker() } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.leading, 12).padding(.top, 8)
            }
        }
    }

    private func endpointDot(past: Bool) -> some View {
        Circle().fill(.white).frame(width: past ? 8 : 10, height: past ? 8 : 10)
            .overlay(Circle().stroke(past ? ArcTheme.routeLinePast : ArcTheme.action,
                                     lineWidth: past ? 2 : 3))
            .opacity(past ? 0.8 : 1)
    }
}
