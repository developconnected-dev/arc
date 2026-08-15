import SwiftUI
import MapKit

/// The single shared map. Renders each flight's great-circle route, airport pins,
/// and (for active flights) the live plane. Camera driven by `MapController`.
struct ArcMapView: View {
    let flights: [Flight]
    @Bindable var controller: MapController
    var friendOverlays: [FriendsStore.FriendMapOverlay] = []

    var body: some View {
        // Read the layer toggles HERE, in the view's own body, not inside the
        // Map content builder. MapKit caches that builder's result, so an
        // @Observable change read only inside it didn't register as a
        // dependency — the layer appeared or vanished on the next pan instead
        // of on the tap. Hoisting the reads makes the toggle immediate.
        let showHazards = controller.showWeatherHazards
        let hazards = controller.hazards
        // Observation hook: the minute tick re-derives estimated plane positions.
        _ = controller.clockTick

        return Map(position: $controller.position) {
            // Drawn FIRST so every route line sits on top of it. Rendered after
            // the arcs, the fills covered the very thing the map is for.
            if showHazards {
                ForEach(routeHazards(hazards)) { hazard in
                    hazardArea(hazard)
                }
            }

            // Friends' flights (Friends tab): route arcs + avatar bubbles
            // with live status pills, Flighty-style. Airborne friends ride
            // the route at clock progress (or their live ADS-B fix);
            // upcoming ones wait at the departure airport; freshly landed
            // ones sit at the arrival airport (no arc — the trip is done).
            ForEach(friendOverlays) { friend in
                let style = RouteStyle(mode: friend.mode)
                let gc = style.path(from: friend.dep, to: friend.arr)
                // Same grammar as the user's own flights: upcoming = solid
                // planned line; flying = solid flown part + dotted remainder;
                // landed = no arc (just the bubble at the arrival airport).
                // Identical stroke language to the user's own flights: glow
                // halo under a crisp 2pt line, endpoint dots at both airports.
                if friend.airborne {
                    let split = min(gc.count - 1, max(0, Int(friend.progress * Double(gc.count - 1))))
                    let flown = Array(gc[0...split])
                    MapPolyline(coordinates: flown)
                        .stroke(style.live.opacity(0.30), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    MapPolyline(coordinates: flown)
                        .stroke(style.live, style: style.flownStroke)
                    MapPolyline(coordinates: Array(gc[split...]))
                        .stroke(style.live.opacity(0.75), style: style.remainderStroke)
                } else if !friend.landed {
                    MapPolyline(coordinates: gc)
                        .stroke(style.live.opacity(0.28), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    MapPolyline(coordinates: gc)
                        .stroke(style.live, style: style.plannedStroke)
                }
                if !friend.landed {
                    Annotation("", coordinate: friend.dep) { endpointDot(past: false, style: style) }
                    Annotation("", coordinate: friend.arr) { endpointDot(past: false, style: style) }

                }
                if friend.showsBubble {
                    let position: CLLocationCoordinate2D = friend.landed
                        ? friend.arr
                        : friend.airborne
                            ? (friend.live ?? gc[min(gc.count - 1, max(0, Int(friend.progress * Double(gc.count - 1))))])
                            : friend.dep
                    Annotation(friend.name, coordinate: position) {
                        FriendMapBubble(name: friend.name,
                                        avatarURL: friend.avatarURL,
                                        chipText: friend.chipText,
                                        chipKind: friend.chipKind,
                                        symbol: friend.symbol)
                    }
                }
            }
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
            // In-app terminal map: every OSM gate. The user's own gate is the
            // yellow chip (Flighty's gate color); the rest are dots that grow
            // labels once the camera is close enough for ~100 chips to fit.
            ForEach(controller.airportGates) { gate in
                Annotation("", coordinate: .init(latitude: gate.lat, longitude: gate.lon)) {
                    if gate.highlighted {
                        HStack(spacing: 3) {
                            Image(systemName: "airplane").font(.system(size: 10, weight: .bold))
                            Text(gate.ref).font(.system(size: 12, weight: .heavy))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(ArcTheme.gate, in: Capsule())
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    } else if controller.cameraSpanDelta < 0.0056 {
                        Text(gate.ref)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: Capsule())
                    } else {
                        Circle().fill(.white.opacity(0.85)).frame(width: 4, height: 4)
                            .overlay(Circle().stroke(ArcTheme.action.opacity(0.8), lineWidth: 1))
                    }
                }
            }
            ForEach(flights) { flight in
                if flight.departureLat != 0 && flight.arrivalLat != 0 {
                    let dep = CLLocationCoordinate2D(latitude: flight.departureLat, longitude: flight.departureLon)
                    let arr = CLLocationCoordinate2D(latitude: flight.arrivalLat, longitude: flight.arrivalLon)
                    let track = flight.trackPoints
                    // A train follows rails, not a great circle. When the leg
                    // carries the real routed path, that IS the line — the arc
                    // is only a stand-in for modes whose provider publishes no
                    // geometry (every flight, and every ferry).
                    let routed = flight.routePath.map {
                        CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                    }

                    let style = RouteStyle(mode: flight.mode)

                    if flight.isCompleted, track.count >= 2 {
                        // Landed: the real recorded path, airport to airport —
                        // what you actually flew, not a theoretical arc. Past
                        // routes render dark and muted, no glow.
                        let flown = [dep] + track.map {
                            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                        } + [arr]
                        MapPolyline(coordinates: flown)
                            .stroke(style.past, style: style.pastStroke)
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
                            .stroke(style.live.opacity(0.30), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        MapPolyline(coordinates: flown)
                            .stroke(style.live, style: style.flownStroke)
                        MapPolyline(coordinates: style.path(from: current, to: arr))
                            .stroke(style.live.opacity(0.75), style: style.remainderStroke)
                    } else if flight.isCompleted {
                        // Past, no recorded track: the routed path if the leg
                        // has one, else the mode's own planned geometry.
                        MapPolyline(coordinates: routed.count >= 3 ? routed : style.path(from: dep, to: arr))
                            .stroke(style.past, style: style.pastStroke)
                    } else {
                        // Upcoming (or active without track): bright + glow.
                        // The routed path wins where it exists — drawing a train
                        // as a straight line across the countryside is the one
                        // thing on this map that is simply untrue. A sailing has
                        // no published geometry, so it gets a rhumb line in the
                        // sea grammar (dotted teal) rather than a flight's arc.
                        let planned = routed.count >= 3 ? routed : style.path(from: dep, to: arr)
                        MapPolyline(coordinates: planned)
                            .stroke(style.live.opacity(0.28), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        MapPolyline(coordinates: planned)
                            .stroke(style.live, style: style.plannedStroke)
                    }

                    Annotation("", coordinate: dep) { endpointDot(past: flight.isCompleted, style: style) }
                    Annotation("", coordinate: arr) { endpointDot(past: flight.isCompleted, style: style) }


                    // A live ADS-B fix when there is one, otherwise the clock's
                    // position on the arc. It used to require a live fix, so an
                    // airborne flight simply had no plane whenever OpenSky had
                    // nothing for that aircraft — which is often, and always
                    // when offline. Friend flights already worked this way.
                    // Skip the aircraft the ADS-B ground-view feed is already
                    // drawing (the orange plane) — otherwise the same physical
                    // plane shows twice: live fix + slightly-stale route
                    // position. Matched by flight row OR tail identity, since
                    // connection legs share one aircraft.
                    if flight.isActive,
                       !(controller.livePlane != nil && isFeedAircraft(flight)),
                       let plane = ownPlane(flight, dep: dep, arr: arr) {
                        Annotation("", coordinate: plane.coordinate) {
                            ActivePlaneGlyph(symbol: flight.mode.symbol,
                                             heading: plane.heading,
                                             isLive: plane.isLive,
                                             // Only the airplane glyph reads as
                                             // directional — a rotated tram or
                                             // ferry front-view just looks broken.
                                             rotates: flight.mode == .air)
                        }
                    }

                    // The inbound rotation, live on the map: for an upcoming
                    // flight whose tail is currently flying toward the
                    // departure airport, draw that leg and the aircraft on it.
                    // "Where's my plane" stops being a text section — you can
                    // watch your bird coming. Suppressed while the ground-view
                    // ADS-B feed draws the same tail in orange.
                    if flight.isUpcoming,
                       !(controller.livePlane != nil && isFeedAircraft(flight)),
                       let inbound = inboundLegOverlay(flight) {
                        MapPolyline(coordinates: inbound.path)
                            .stroke(Color(red: 0.83, green: 0.27, blue: 0.75).opacity(0.55),
                                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [1, 5]))
                        Annotation("", coordinate: inbound.position) {
                            Image(systemName: "airplane")
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(ArcTheme.smartGradient)
                                .rotationEffect(.degrees(inbound.heading - 90))
                                .shadow(color: .black.opacity(0.35), radius: 2)
                        }
                    }
                }
            }
        }
        .mapStyle(controller.style == .hybrid ? .hybrid(elevation: .realistic) : .standard(elevation: .realistic))
        // Keep an airborne flight's plane creeping along its arc with no live
        // fix and no network: the position is derived from the clock, so this
        // only needs a nudge to re-render. Zero network calls. Inbound
        // rotation legs need the same heartbeat, so upcoming flights with a
        // known rotation count too.
        .task(id: flights.contains { $0.isActive || ($0.isUpcoming && !$0.rotationLegs.isEmpty) }) {
            guard flights.contains(where: { $0.isActive || ($0.isUpcoming && !$0.rotationLegs.isEmpty) })
            else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                controller.clockTick += 1
            }
        }
        // Tell the weather toggle whether it has anything to say: a badge on
        // the control beats making the user toggle blind.
        .task(id: "\(controller.hazards.count)-\(flights.count)") {
            controller.hazardsTouchRoutes = !routeHazards(controller.hazards).isEmpty
        }
        .mapControlVisibility(.hidden)
        .onMapCameraChange(frequency: .onEnd) { context in
            controller.cameraSpanDelta = context.region.span.latitudeDelta
        }
    }

    /// Avatar + status pill, the Flighty friends-map bubble.
    private struct FriendMapBubble: View {
        let name: String
        let avatarURL: String?
        let chipText: String
        let chipKind: FriendFlightMath.ChipKind
        let symbol: String

        var body: some View {
            let (bg, fg): (Color, Color) = switch chipKind {
            case .landed: (ArcTheme.gate, .black)
            case .delayed: (ArcTheme.late, .white)
            case .inFlight: (ArcTheme.onTime, .white)
            case .boarding: (ArcTheme.action, .white)
            case .countdown: (Color(.systemGray6), .primary)
            }
            VStack(spacing: 3) {
                FriendAvatar(name: name, size: 34, avatarURL: avatarURL)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                HStack(spacing: 3) {
                    Image(systemName: symbol).font(.system(size: 7, weight: .bold))
                    Text(chipText).font(.system(size: 9, weight: .heavy))
                }
                .foregroundStyle(fg)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(bg, in: Capsule())
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            }
        }
    }

    /// The active flight's own plane, with a slow breathing halo — the one
    /// aircraft on the map that's *yours, right now* reads as alive.
    private struct ActivePlaneGlyph: View {
        let symbol: String
        let heading: Double
        let isLive: Bool
        let rotates: Bool
        @State private var breathe = false

        var body: some View {
            ZStack {
                Circle()
                    .fill(ArcTheme.routeLine.opacity(0.35))
                    .frame(width: 34, height: 34)
                    .scaleEffect(breathe ? 1.25 : 0.8)
                    .opacity(breathe ? 0.1 : 0.45)
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(rotates ? heading - 90 : 0))
                    .shadow(radius: 2)
                    // Estimated positions read slightly softer than a real
                    // fix, so the map never overstates what it knows.
                    .opacity(isLive ? 1 : 0.85)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }
        }
    }

    /// The currently-flying leg of an upcoming flight's rotation chain: path,
    /// clock-estimated position, and heading. Nil when the tail isn't in the
    /// air (parked feeders and landed inbounds have nothing to show).
    private func inboundLegOverlay(_ flight: Flight)
    -> (path: [CLLocationCoordinate2D], position: CLLocationCoordinate2D, heading: Double)? {
        let now = Date.now
        guard let leg = flight.rotationLegs.first(where: { leg in
            guard leg.status != "landed",
                  let dep = leg.scheduledDeparture, let arr = leg.effectiveArrival
            else { return false }
            return leg.status.lowercased() == "active" || (dep <= now && now < arr)
        }),
        let depAirport = ReferenceData.shared.airport(leg.depIATA),
        let arrAirport = ReferenceData.shared.airport(leg.arrIATA),
        let dep = leg.scheduledDeparture, let arr = leg.effectiveArrival, arr > dep
        else { return nil }
        let gc = GeoMath.greatCircle(from: depAirport.coordinate, to: arrAirport.coordinate)
        let progress = min(1, max(0, now.timeIntervalSince(dep) / arr.timeIntervalSince(dep)))
        guard let pos = GeoMath.position(along: gc, progress: progress) else { return nil }
        return (gc, pos.coordinate, pos.heading)
    }

    private func endpointDot(past: Bool, style: RouteStyle = RouteStyle(mode: .air)) -> some View {
        Circle().fill(.white).frame(width: past ? 8 : 10, height: past ? 8 : 10)
            .overlay(Circle().stroke(past ? style.past : style.endpoint,
                                     lineWidth: past ? 2 : 3))
            .opacity(past ? 0.8 : 1)
    }

    /// One visual grammar per mode, so the map itself says what kind of
    /// journey a line is before any label does.
    ///
    /// Air: the great-circle arc, sky blue, solid with a glow — Arc's original
    /// language. Rail: the same stroke on the REAL routed path (drawn from
    /// `routePath` by the caller). Sea: a rhumb line — straight on the map,
    /// which is what a ship steers and what a chart draws — in teal, dotted
    /// like a wake. A sailing drawn as a solid blue arc read as a flight; a
    /// straight line in the flight's own colour still did.
    struct RouteStyle {
        let mode: TripMode

        var live: Color { mode == .sea ? ArcTheme.seaLine : ArcTheme.routeLine }
        var past: Color { mode == .sea ? ArcTheme.seaLinePast : ArcTheme.routeLinePast }
        var endpoint: Color { mode == .sea ? ArcTheme.seaLine : ArcTheme.action }

        /// Planned geometry between two points when no routed path exists.
        func path(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
            mode == .sea ? GeoMath.rhumbLine(from: a, to: b) : GeoMath.greatCircle(from: a, to: b)
        }

        // Same stroke language as every other route on the map — solid line,
        // glow halo, dotted remainder — with colour alone telling sea from
        // air. Pattern and weight tricks were tried; the geometry (a real
        // ferry line vs a great-circle arc) plus teal is all it needs.
        var plannedStroke: StrokeStyle { StrokeStyle(lineWidth: 2, lineCap: .round) }
        var flownStroke: StrokeStyle { StrokeStyle(lineWidth: 2, lineCap: .round) }
        var remainderStroke: StrokeStyle { StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 4]) }
        var pastStroke: StrokeStyle { StrokeStyle(lineWidth: 1.5, lineCap: .round) }
    }

    /// Is this flight riding the aircraft the ground-view ADS-B feed is
    /// drawing? True on the watched flight itself or any flight sharing its
    /// tail (icao24 / registration).
    private func isFeedAircraft(_ flight: Flight) -> Bool {
        if controller.livePlaneFlightID == flight.id { return true }
        let keys = controller.livePlaneAircraftKeys
        guard !keys.isEmpty else { return false }
        return [flight.aircraftICAO24, flight.aircraftRegistration]
            .compactMap { $0?.lowercased() }
            .contains(where: keys.contains)
    }

    /// Where to draw this flight's plane: the live fix if we have one, else the
    /// clock's position along the great circle.
    private func ownPlane(_ flight: Flight,
                          dep: CLLocationCoordinate2D,
                          arr: CLLocationCoordinate2D)
    -> (coordinate: CLLocationCoordinate2D, heading: Double, isLive: Bool)? {
        if let lat = flight.liveLat, let lon = flight.liveLon {
            return (CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    flight.liveHeading ?? GeoMath.bearing(from: dep, to: arr),
                    true)
        }
        // Walk the same geometry the map draws for this mode — a ferry
        // estimated along a great circle would sit beside its own dotted line.
        let planned = flight.routePath.count >= 3
            ? flight.routePath.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            : RouteStyle(mode: flight.mode).path(from: dep, to: arr)
        guard let estimated = GeoMath.position(along: planned, progress: flight.progress) else { return nil }
        return (estimated.coordinate, estimated.heading, false)
    }

    /// Hazards touching any route currently drawn, de-duplicated — one advisory
    /// can sit near several of them.
    private func routeHazards(_ all: [FlightAPIClient.WeatherHazard]) -> [FlightAPIClient.WeatherHazard] {
        guard !all.isEmpty else { return [] }
        var routes: [(CLLocationCoordinate2D, CLLocationCoordinate2D)] = []
        for flight in flights where !flight.isCompleted
            && flight.departureLat != 0 && flight.arrivalLat != 0 {
            routes.append((CLLocationCoordinate2D(latitude: flight.departureLat, longitude: flight.departureLon),
                           CLLocationCoordinate2D(latitude: flight.arrivalLat, longitude: flight.arrivalLon)))
        }
        for friend in friendOverlays where !friend.landed {
            routes.append((friend.dep, friend.arr))
        }
        var seen = Set<String>()
        var out: [FlightAPIClient.WeatherHazard] = []
        for (dep, arr) in routes {
            for hazard in GeoMath.hazards(all, near: dep, to: arr) where seen.insert(hazard.id).inserted {
                out.append(hazard)
            }
        }
        return out
    }

    /// A published advisory, drawn as the polygon it actually is.
    ///
    /// No text pill: labels on every area buried the routes, and a black capsule
    /// read as chrome rather than weather. The shape and its tint carry the
    /// meaning, and only a severe hazard gets a small glyph to draw the eye.
    @MapContentBuilder
    private func hazardArea(_ hazard: FlightAPIClient.WeatherHazard) -> some MapContent {
        let points = hazard.coords.map {
            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
        }
        let tint = hazard.severe ? Color.orange : Color.cyan
        MapPolygon(coordinates: points)
            .foregroundStyle(tint.opacity(hazard.severe ? 0.16 : 0.10))
            .stroke(tint.opacity(0.55), lineWidth: 1)
        if hazard.severe, let centre = GeoMath.centroid(points) {
            Annotation(hazard.label, coordinate: centre) {
                Image(systemName: "cloud.bolt.rain.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.orange)
                    .shadow(color: .black.opacity(0.35), radius: 2)
            }
            .annotationTitles(.hidden)
        }
    }
}
