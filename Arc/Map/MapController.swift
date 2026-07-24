import SwiftUI
import MapKit

@MainActor
@Observable
final class MapController {
    var position: MapCameraPosition = .automatic
    var style: MapStyleKind = .standard
    var gateMarker: GateMarker?
    var livePlane: LivePlane?
    var airportView: AirportView?
    var airportGates: [AirportGate] = []
    /// Latest camera span (updated on gesture end) — gate labels appear only
    /// when zoomed in enough that ~100 chips wouldn't collapse into noise.
    var cameraSpanDelta: Double = 180
    private var styleBeforeAirport: MapStyleKind?

    struct GateMarker: Equatable {
        let lat: Double
        let lon: Double
        let label: String
    }

    struct AirportView: Equatable {
        let iata: String
        let name: String
    }

    struct AirportGate: Equatable, Identifiable {
        let ref: String
        let lat: Double
        let lon: Double
        let highlighted: Bool   // the user's own gate
        // OSM occasionally repeats a ref across terminals — key on position
        // too so ForEach never sees duplicate ids.
        var id: String { "\(ref)|\(lat)|\(lon)" }
    }

    /// The user's actual aircraft, live (ADS-B), while the airport gate view
    /// is open — arriving, taxiing, parking.
    struct LivePlane: Equatable {
        let lat: Double
        let lon: Double
        let heading: Double
        let onGround: Bool
    }

    /// Zoom tight onto a gate and drop the plane there — the "your plane is
    /// parked at A54" view after landing.
    func showGate(lat: Double, lon: Double, label: String) {
        gateMarker = GateMarker(lat: lat, lon: lon, label: label)
        withAnimation(.easeInOut(duration: 0.8)) {
            // Center offset SOUTH of the gate: the detail sheet covers the
            // lower ~55% of the screen, so a dead-center gate would sit
            // exactly behind it — shifting the camera down puts the marker
            // in the visible upper half.
            position = .region(MKCoordinateRegion(
                center: .init(latitude: lat - 0.0011, longitude: lon),
                span: MKCoordinateSpan(latitudeDelta: 0.0045, longitudeDelta: 0.0045)))
        }
    }

    /// The in-app terminal map: cinematic dive from wherever the camera is
    /// down onto the airport, satellite imagery on, every OSM gate rendered,
    /// the user's own gate highlighted. Replaces the old Apple Maps deep
    /// link — personal app, so no reason to bounce the user out.
    func showAirport(iata: String, name: String, lat: Double, lon: Double,
                     gates: [AirportGate]) {
        airportView = AirportView(iata: iata, name: name)
        airportGates = gates
        gateMarker = nil
        if styleBeforeAirport == nil { styleBeforeAirport = style }
        style = .hybrid   // satellite = actual terminals, aprons, taxiways
        // Center between the airport reference point and the highlighted gate
        // (terminals can sit >1km from the reference point), offset south so
        // the medium detail sheet doesn't cover the interesting half.
        let focus = gates.first(where: \.highlighted)
            .map { (lat: ($0.lat + lat) / 2, lon: ($0.lon + lon) / 2) } ?? (lat: lat, lon: lon)
        withAnimation(.easeInOut(duration: 1.4)) {
            position = .region(MKCoordinateRegion(
                center: .init(latitude: focus.lat - 0.003, longitude: focus.lon),
                span: MKCoordinateSpan(latitudeDelta: 0.014, longitudeDelta: 0.014)))
        }
    }

    func clearGateMarker() {
        gateMarker = nil
        livePlane = nil
        airportView = nil
        airportGates = []
        if let restore = styleBeforeAirport {
            style = restore
            styleBeforeAirport = nil
        }
    }

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
