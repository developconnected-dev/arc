import SwiftUI
import MapKit

@MainActor
@Observable
final class MapController {
    var position: MapCameraPosition = .automatic
    var style: MapStyleKind = .standard
    var gateMarker: GateMarker?
    var livePlane: LivePlane?
    /// Which flight the ADS-B feed is tracking — the map suppresses that
    /// flight's route-derived plane so the same aircraft never renders twice
    /// (orange live fix + white estimated position) while a ground view is up.
    var livePlaneFlightID: UUID?
    /// The tracked tail's identifiers (icao24 / registration, lowercased).
    /// Connection legs ride the same aircraft, so a different Flight row can
    /// still be the plane the feed is drawing — match on identity, not row.
    var livePlaneAircraftKeys: Set<String> = []
    var airportView: AirportView?
    var airportGates: [AirportGate] = []
    /// Latest camera span (updated on gesture end) — gate labels appear only
    /// when zoomed in enough that ~100 chips wouldn't collapse into noise.
    var cameraSpanDelta: Double = 180
    /// Off by default: an en-route hazard layer is a deliberate thing to look
    /// at, not something to leave painted over every flight.
    var showWeatherHazards: Bool = false
    /// True when a published advisory actually intersects a drawn route —
    /// drives the badge on the weather toggle so the user knows the layer
    /// has something to show before turning it on.
    var hazardsTouchRoutes: Bool = false

    /// Minute heartbeat so a clock-estimated plane creeps along its arc between
    /// data refreshes. Costs nothing: it triggers no network call, just a
    /// re-derivation of a position from the clock.
    var clockTick = 0

    /// Routes drawing themselves onto the map right now — the add/import
    /// moment. Empty the rest of the time.
    ///
    /// Read this in a VIEW'S OWN BODY, not only inside a `Map` content
    /// builder: MapKit caches that builder's result, so an `@Observable` read
    /// buried in it never registers as a dependency — the same trap the
    /// weather-layer toggle fell into, where the layer appeared on the next
    /// pan instead of on the tap.
    var routeReveals: [RouteReveal] = []
    /// How far every route in `routeReveals` has drawn itself on, 0…1. One
    /// value for the batch: one beat, and one observation per frame.
    var revealProgress: Double = 0
    /// The stroke has reached the arrival end (or nothing is drawing).
    var isRevealComplete: Bool { revealProgress >= 1 }

    /// True while a just-added trip's route is drawing itself on. The camera
    /// belongs to the reveal for that window: saving a trip also changes the
    /// flight list, and the refit that hangs off THAT would otherwise frame
    /// every route the user owns and undo the fit the moment was built around.
    var isRevealingRoutes: Bool { !routeReveals.isEmpty }
    private var revealTask: Task<Void, Never>?
    /// The clock a reveal's progress is measured on. System uptime rather
    /// than the wall clock: an NTP correction or a hand-set clock stepping
    /// back mid-draw would otherwise leave the loop at zero until wall time
    /// caught up — with the reveal owning the camera the whole while. Tests
    /// feed it a clock of their own.
    var revealUptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

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
        livePlaneFlightID = nil
        livePlaneAircraftKeys = []
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
    func fitAll(_ flights: [Flight], padding: Double = 1.25, band: MapBand = .upperHalf) {
        var coords: [CLLocationCoordinate2D] = []
        for f in flights where f.departureLat != 0 && f.arrivalLat != 0 {
            coords.append(.init(latitude: f.departureLat, longitude: f.departureLon))
            coords.append(.init(latitude: f.arrivalLat, longitude: f.arrivalLon))
        }
        if coords.isEmpty {
            position = .automatic
        } else {
            frame(coords, band: band, padding: padding)
        }
    }

    /// Frame the camera on a single flight's route (detail sheet at medium
    /// covers the lower half — the arc goes above it).
    func focus(on flight: Flight, band: MapBand = .upperHalf, animated: Bool = true) {
        // Frame what will actually be DRAWN. A routed leg can bulge far outside
        // the arc between its endpoints — an ICE from München to Hamburg reaches
        // Berlin, 2° east of either — so framing the arc would crop the very
        // line the user opened the sheet to look at.
        //
        // And the same geometry the map draws when there is no routed path:
        // a flight's arc, but a train's or a sailing's straight ground line —
        // the arc between two stations peaks degrees north of a long
        // east–west leg, and framing it put the real line low in the frame.
        frame(RouteReveal.geometry(for: flight), band: band, padding: 1.3, animated: animated)
    }

    /// Frame `coords` in the UPPER half of the screen — for content shown
    /// above a half-screen sheet.
    func frameInUpperHalf(_ coords: [CLLocationCoordinate2D], padding: Double = 1.25, animated: Bool = true) {
        frame(coords, band: .upperHalf, padding: padding, animated: animated)
    }

    /// Frame `coords` inside `band`, the part of the screen nothing covers.
    func frame(_ coords: [CLLocationCoordinate2D], band: MapBand, padding: Double = 1.25, animated: Bool = true) {
        guard let region = Self.region(fitting: coords, band: band, padding: padding) else { return }
        withAnimation(animated ? .easeInOut(duration: 0.8) : nil) { position = .region(region) }
    }

    /// In portrait the LONGITUDE span usually decides the zoom MapKit
    /// actually shows, so the vertical placement is computed from the
    /// EFFECTIVE displayed latitude span, not the fitted one — a plain
    /// latitude offset gets swallowed whole.
    nonisolated static func region(fitting coords: [CLLocationCoordinate2D], band: MapBand,
                                   padding: Double) -> MKCoordinateRegion? {
        guard var region = GeoMath.region(fitting: coords, paddingFactor: padding) else { return nil }
        let portraitAspect = 2.16   // full-screen map height / width
        let latScale = max(0.2, cos(region.center.latitude * .pi / 180))
        // Capped: a transatlantic longitude span would otherwise demand an
        // impossible >180° vertical region and clamp into garbage — wide
        // routes get best-effort placement instead.
        let effectiveLat = min(70, max(region.span.latitudeDelta,
                                       region.span.longitudeDelta * portraitAspect * latScale))
        let visible = max(0.2, band.bottom - band.top)
        let span = min(160, effectiveLat / visible)
        let bandCentre = (band.top + band.bottom) / 2
        region.span.latitudeDelta = span
        region.center.latitude = max(-75, min(75, region.center.latitude - (0.5 - bandCentre) * span))
        return region
    }

    // MARK: - The add / import moment

    /// Draw freshly added or imported trips onto the map: fit the camera to
    /// what just arrived, then grow each route over ~1 second. `holdRoutes`
    /// and `startReveal` in one step, for a trip that lands on a map that is
    /// already in view (an accepted invite).
    func revealRoutes(for flights: [Flight]) {
        holdRoutes(for: flights)
        startReveal()
    }

    /// Claim the moment for trips that just landed, without drawing yet.
    ///
    /// A trip is saved while the Add sheet is still up, and the map is
    /// visible behind it as it slides away — so from the save on, the map
    /// must HIDE the settled line, or the route shows whole for half a
    /// second, blinks out, and draws itself on again. Holding registers the
    /// reveal at progress zero (the map draws nothing for a held leg) and
    /// moves the camera now, so the frame is settled by the time there is
    /// something on it to watch. `startReveal` starts the clock.
    ///
    /// ONE beat for the whole batch. Trips held before the draw starts join
    /// the same batch — one camera move that frames all of them and one
    /// shared stroke — because reveals racing each other with a camera fit
    /// apiece is exactly the loading theatre this exists instead of. A hold
    /// that arrives mid-draw belongs to the newer trip and takes over.
    func holdRoutes(for flights: [Flight]) {
        // Geometry is fixed HERE, synchronously with the save that asked for
        // the reveal: exactly what the settled map will draw for each leg, so
        // nothing shifts at the handover — and no await ever separates these
        // reads from the models they come from, so a later swipe-delete can't
        // pull a trip out from underneath them.
        var planned: [RouteReveal] = []
        for flight in flights {
            let path = RouteReveal.geometry(for: flight)
            guard path.count >= 2 else { continue }
            planned.append(RouteReveal(id: flight.id, path: path))
        }
        // Nothing drawable — a past trip, a hand-typed train with no
        // coordinates — is not an add taking over the moment, it is no moment
        // at all. Decided BEFORE the running reveal is touched, so asking on
        // behalf of such a trip can't tear down a route still drawing itself.
        guard !planned.isEmpty else { return }
        if revealTask == nil {
            // Held, not yet drawing: the newcomer joins the batch.
            let held = routeReveals.filter { reveal in !planned.contains { $0.id == reveal.id } }
            routeReveals = held + planned
        } else {
            // A second add mid-draw belongs to the newer trip: cancel first, and
            // clear so the previous route is handed straight back to the settled
            // map rather than freezing part-drawn.
            revealTask?.cancel()
            revealTask = nil
            routeReveals = planned
        }
        revealProgress = 0
        // Camera first, so the stroke draws into a frame that already holds
        // the whole route instead of chasing it off the edge.
        frameInUpperHalf(routeReveals.flatMap { $0.path }, padding: 1.3)
    }

    /// Start the clock on whatever is held. Nothing held, or already
    /// drawing: nothing to do — so a belt-and-braces caller can't restart a
    /// draw or conjure one.
    func startReveal() {
        guard !routeReveals.isEmpty, revealTask == nil else { return }
        revealTask = Task { @MainActor in
            let startedAt = revealUptime()
            while !Task.isCancelled {
                // Progress comes from a clock rather than a frame count:
                // `Task.sleep` is a floor, not a metronome, and an
                // accumulating counter would stretch the beat under load.
                let elapsed = revealUptime() - startedAt
                let progress = RouteReveal.eased(elapsed / RouteReveal.drawDuration)
                revealProgress = progress
                if elapsed >= RouteReveal.drawDuration { break }
                try? await Task.sleep(for: .seconds(RouteReveal.frameInterval))
            }
            // Hand the routes and the camera back to the settled map. It
            // draws the same geometry the reveal just finished, so nothing
            // moves — the reveal only ever owned the line while it grew. A
            // cancelled task leaves `routeReveals` alone on the way out: a
            // newer add owns it already.
            if !Task.isCancelled {
                routeReveals = []
                revealTask = nil
            }
        }
    }

    /// Give up the moment — held or drawing — and hand every line straight
    /// back to the settled map. For a reveal that would play to nobody: a
    /// detail sheet about to cover the map and take the camera for its own
    /// flight.
    func cancelReveal() {
        revealTask?.cancel()
        revealTask = nil
        routeReveals = []
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
