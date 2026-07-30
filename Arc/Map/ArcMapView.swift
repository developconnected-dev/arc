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
        let showTerminator = controller.showDayNightTerminator
        let showHazards = controller.showWeatherHazards
        let hazards = controller.hazards

        return Map(position: $controller.position) {
            // Drawn FIRST so every route line sits on top of it. Rendered after
            // the arcs, the fills covered the very thing the map is for.
            if showHazards {
                ForEach(routeHazards(hazards)) { hazard in
                    hazardArea(hazard)
                }
            }

            if showTerminator {
                MapPolygon(coordinates: GeoMath.solarTerminatorPolygon(date: .now))
                    .foregroundStyle(Color.indigo.opacity(0.28))
                    .stroke(Color.orange.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }

            // Friends' flights (Friends tab): route arcs + avatar bubbles
            // with live status pills, Flighty-style. Airborne friends ride
            // the route at clock progress (or their live ADS-B fix);
            // upcoming ones wait at the departure airport; freshly landed
            // ones sit at the arrival airport (no arc — the trip is done).
            ForEach(friendOverlays) { friend in
                let gc = GeoMath.greatCircle(from: friend.dep, to: friend.arr)
                // Same grammar as the user's own flights: upcoming = solid
                // planned line; flying = solid flown part + dotted remainder;
                // landed = no arc (just the bubble at the arrival airport).
                // Identical stroke language to the user's own flights: glow
                // halo under a crisp 2pt line, endpoint dots at both airports.
                if friend.airborne {
                    let split = min(gc.count - 1, max(0, Int(friend.progress * Double(gc.count - 1))))
                    let flown = Array(gc[0...split])
                    MapPolyline(coordinates: flown)
                        .stroke(ArcTheme.routeLine.opacity(0.30), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    MapPolyline(coordinates: flown)
                        .stroke(ArcTheme.routeLine, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    MapPolyline(coordinates: Array(gc[split...]))
                        .stroke(ArcTheme.routeLine.opacity(0.75),
                                style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 4]))
                } else if !friend.landed {
                    MapPolyline(coordinates: gc)
                        .stroke(ArcTheme.routeLine.opacity(0.28), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    MapPolyline(coordinates: gc)
                        .stroke(ArcTheme.routeLine, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
                if !friend.landed {
                    Annotation("", coordinate: friend.dep) { endpointDot(past: false) }
                    Annotation("", coordinate: friend.arr) { endpointDot(past: false) }

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
                                        chipKind: friend.chipKind)
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
                            .stroke(ArcTheme.routeLine.opacity(0.75),
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 4]))
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
        .onMapCameraChange(frequency: .onEnd) { context in
            controller.cameraSpanDelta = context.region.span.latitudeDelta
        }
        .overlay(alignment: .topLeading) {
            if controller.gateMarker != nil || controller.airportView != nil {
                Button { controller.clearGateMarker() } label: {
                    Label(controller.airportView.map { "Back · \($0.iata)" } ?? "Back",
                          systemImage: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.leading, 12).padding(.top, 8)
            }
        }
    }

    /// Avatar + status pill, the Flighty friends-map bubble.
    private struct FriendMapBubble: View {
        let name: String
        let avatarURL: String?
        let chipText: String
        let chipKind: FriendFlightMath.ChipKind

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
                    Image(systemName: "airplane").font(.system(size: 7, weight: .bold))
                    Text(chipText).font(.system(size: 9, weight: .heavy))
                }
                .foregroundStyle(fg)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(bg, in: Capsule())
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            }
        }
    }

    private func endpointDot(past: Bool) -> some View {
        Circle().fill(.white).frame(width: past ? 8 : 10, height: past ? 8 : 10)
            .overlay(Circle().stroke(past ? ArcTheme.routeLinePast : ArcTheme.action,
                                     lineWidth: past ? 2 : 3))
            .opacity(past ? 0.8 : 1)
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
