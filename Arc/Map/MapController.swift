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
    /// Off by default: an en-route hazard layer is a deliberate thing to look
    /// at, not something to leave painted over every flight.
    var showWeatherHazards: Bool = false
    var showDayNightTerminator: Bool = true

    /// Minute heartbeat so a clock-estimated plane creeps along its arc between
    /// data refreshes. Costs nothing: it triggers no network call, just a
    /// re-derivation of a position from the clock.
    var clockTick = 0

    /// Published SIGMET/AIRMET areas, refreshed at most every 10 minutes —
    /// they're issued hourly and valid for hours, so anything keener is waste.
    var hazards: [FlightAPIClient.WeatherHazard] = []
    private var hazardsFetchedAt: Date?

    func refreshHazardsIfNeeded() async {
        if let last = hazardsFetchedAt, Date.now.timeIntervalSince(last) < 600 { return }
        hazardsFetchedAt = .now
        hazards = (try? await FlightAPIClient.shared.weatherHazards()) ?? hazards
    }
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

    /// Frame the camera to fit all given flights' routes — in the visible
    /// upper half, since a sheet always owns the bottom of every page.
    func fitAll(_ flights: [Flight], padding: Double = 1.25) {
        var coords: [CLLocationCoordinate2D] = []
        for f in flights where f.departureLat != 0 && f.arrivalLat != 0 {
            coords.append(.init(latitude: f.departureLat, longitude: f.departureLon))
            coords.append(.init(latitude: f.arrivalLat, longitude: f.arrivalLon))
        }
        if coords.isEmpty {
            position = .automatic
        } else {
            frameInUpperHalf(coords, padding: padding)
        }
    }

    /// Frame the camera on a single flight's route (detail sheet at medium
    /// covers the lower half — the arc goes above it).
    func focus(on flight: Flight) {
        frameInUpperHalf(GeoMath.greatCircle(
            from: .init(latitude: flight.departureLat, longitude: flight.departureLon),
            to: .init(latitude: flight.arrivalLat, longitude: flight.arrivalLon)), padding: 1.3)
    }

    /// Frame `coords` in the UPPER half of the screen — for content shown
    /// above a half-screen sheet. In portrait the LONGITUDE span usually
    /// decides the zoom MapKit actually shows, so the vertical shift must be
    /// computed from the EFFECTIVE displayed latitude span, not the fitted
    /// one — a plain latitude offset gets swallowed whole.
    func frameInUpperHalf(_ coords: [CLLocationCoordinate2D], padding: Double = 1.25) {
        guard var region = GeoMath.region(fitting: coords, paddingFactor: padding) else { return }
        let portraitAspect = 2.16   // full-screen map height / width
        let latScale = max(0.2, cos(region.center.latitude * .pi / 180))
        // Capped: a transatlantic longitude span would otherwise demand an
        // impossible >180° vertical region and clamp into garbage — wide
        // routes get best-effort placement instead.
        let effectiveLat = min(70, max(region.span.latitudeDelta,
                                       region.span.longitudeDelta * portraitAspect * latScale))
        region.span.latitudeDelta = min(160, effectiveLat * 2.0)
        region.center.latitude = max(-75, min(75, region.center.latitude - effectiveLat / 2))
        withAnimation(.easeInOut(duration: 0.8)) { position = .region(region) }
    }

    /// Frame one route in the upper half (friend-flight detail).
    func focusRoute(dep: CLLocationCoordinate2D, arr: CLLocationCoordinate2D) {
        frameInUpperHalf(GeoMath.greatCircle(from: dep, to: arr))
    }

    /// Follow a live plane position (used in-flight).
    func follow(lat: Double, lon: Double) {
        withAnimation(.easeInOut(duration: 0.8)) {
            position = .region(MKCoordinateRegion(
                center: .init(latitude: lat, longitude: lon),
                span: MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 30)))
        }
    }

    /// Keeps the aircraft AND its gate in frame while it taxis.
    ///
    /// The camera used to be parked on the gate, so at a big airport — where a
    /// plane can land 4km away and taxi for fifteen minutes — the aircraft
    /// drove straight off screen and the user watched an empty apron. Framing
    /// both means the gap closes on its own: the view tightens as the plane
    /// arrives, ending parked at the jetbridge.
    /// Camera to an aircraft that is NOT at the expected airport — parked at
    /// another field or airborne mid-rotation. Airborne gets a wide frame (a
    /// cruising dot outruns a tight one in seconds); on the ground a
    /// city-scale frame shows which airport the plane is sitting at.
    func frameRemotePlane(plane: CLLocationCoordinate2D, airborne: Bool) {
        let span = airborne ? 2.2 : 0.12
        withAnimation(.easeInOut(duration: 1.0)) {
            position = .region(MKCoordinateRegion(
                center: plane,
                span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)))
        }
    }

    func followTaxi(plane: CLLocationCoordinate2D, gate: CLLocationCoordinate2D?) {
        let points = [plane] + (gate.map { [$0] } ?? [])
        let lats = points.map(\.latitude), lons = points.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return }

        // Deliberately NOT GeoMath.region(fitting:) — that floors the span at 2°
        // (~220km) because it exists to frame whole routes, which at airport
        // scale means the camera never moves at all.
        //
        // The floor here is gate-sized instead: fitting two points a few metres
        // apart would otherwise zoom to the length of the aircraft.
        let latDelta = max((maxLat - minLat) * 1.8, 0.0045)
        let lonDelta = max((maxLon - minLon) * 1.8, 0.0045)

        // Same trap frameInUpperHalf exists for: in portrait the LONGITUDE span
        // usually decides what MapKit actually displays, stretching the latitude
        // span to fit. Shifting by a fraction of `latDelta` is then a fraction
        // of nothing — the aircraft stayed behind the detail sheet. Offset from
        // the EFFECTIVE displayed height instead.
        let portraitAspect = 2.16
        let latScale = max(0.2, cos(((minLat + maxLat) / 2) * .pi / 180))
        let effectiveLat = max(latDelta, lonDelta * portraitAspect * latScale)

        let region = MKCoordinateRegion(
            // Sheet owns the bottom half, so put the action in the top half.
            center: .init(latitude: (minLat + maxLat) / 2 - effectiveLat * 0.25,
                          longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta))

        withAnimation(.easeInOut(duration: 1.0)) { position = .region(region) }
    }
}
