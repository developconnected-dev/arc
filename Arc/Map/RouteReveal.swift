import Foundation
import CoreLocation

/// One route drawing itself onto the shared map, which is what adding or
/// importing a trip looks like: the row lands in My Trips and the line reaches
/// across the map at the same moment. Nothing is loading by then — the trip is
/// already saved — so nothing here is an overlay, a spinner or a splash. The
/// line arriving IS the confirmation.
///
/// This is not an animated line, because `MapPolyline` has no trim: it draws
/// exactly the coordinates it is handed and no fraction of them. So the line
/// GROWS instead — `drawn(_:to:)` hands back the leading part of the finished
/// geometry with the tip interpolated between samples, and the map rebuilds it
/// each frame while `progress` climbs.
struct RouteReveal: Identifiable {
    /// The leg this route belongs to. While a reveal exists the map draws THIS
    /// for that leg instead of its settled line, so the finished route can
    /// never sit underneath the one still being drawn.
    let id: UUID
    /// The finished geometry, fixed when the reveal begins: exactly the points
    /// the settled map draws once it's over, so nothing shifts at the handover.
    let path: [CLLocationCoordinate2D]

    /// How much of `path` is laid down at `progress` (0…1). Progress is not
    /// stored here: one batch draws at ONE progress — `MapController`'s —
    /// so a batch can't drift apart and the map is invalidated once per
    /// frame rather than once per leg.
    func drawnPath(at progress: Double) -> [CLLocationCoordinate2D] {
        Self.drawn(path, to: progress)
    }
}

extension RouteReveal {
    /// The beat itself: about a second, whatever the route's length. A
    /// Zurich→JFK arc and a Piraeus→Santorini crossing take the same time to
    /// draw, because the duration belongs to the moment rather than to the
    /// distance.
    static let drawDuration: TimeInterval = 1.0

    /// ~60fps. The line grows by re-rendering, so this is how often the map's
    /// content is rebuilt — for one second, and only while a trip is landing.
    static let frameInterval: TimeInterval = 1.0 / 60.0

    /// Whether the map draws this leg at all — the same test `ArcMapView`
    /// applies, so a reveal can never animate a line that then isn't there. A
    /// hand-typed train carries no coordinates (there is no offline station
    /// table to resolve one against), and its row appearing is the whole event.
    static func isDrawable(_ flight: Flight) -> Bool {
        flight.departureLat != 0 && flight.arrivalLat != 0
    }

    /// The geometry a leg draws on, per mode — the same grammar the settled
    /// map already speaks, read out of `RouteStyle` rather than reinvented.
    ///
    /// Air gets the great circle it flies. Sea gets the rhumb line a chart
    /// draws. Rail gets its REAL routed path wherever the provider published
    /// one, and a straight ground segment where it didn't — never a
    /// great-circle arc, because on this map an arc is how a flight is
    /// recognised, and a train wearing one is the one thing the map must not
    /// say.
    static func geometry(for flight: Flight) -> [CLLocationCoordinate2D] {
        guard isDrawable(flight) else { return [] }
        let routed = flight.routePath.map {
            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
        }
        if routed.count >= 3 { return routed }
        return ArcMapView.RouteStyle(mode: flight.mode).path(
            from: CLLocationCoordinate2D(latitude: flight.departureLat,
                                         longitude: flight.departureLon),
            to: CLLocationCoordinate2D(latitude: flight.arrivalLat,
                                       longitude: flight.arrivalLon))
    }

    /// Whether a flight-list change that landed while a reveal owned the
    /// camera still needs the refit it was denied, once the reveal ends.
    ///
    /// The change the reveal is FOR — the trip it is framing arriving in
    /// the list — is spent: the reveal's frame is the camera that change
    /// deserves. Anything else is not: a trip deleted mid-draw leaves the
    /// camera on a route that isn't there, and a trip that arrived by some
    /// other path in that second was never framed at all.
    static func listChangeNeedsRefit(previous: [UUID], current: [UUID],
                                     revealing: Set<UUID>) -> Bool {
        let before = Set(previous), after = Set(current)
        let removedSomething = !before.subtracting(after).isEmpty
        let addedAStranger = !after.subtracting(before).isSubset(of: revealing)
        return removedSomething || addedAStranger
    }

    /// Smoothstep, so the stroke eases out of the departure dot and settles
    /// into the arrival one instead of stopping dead at full speed.
    static func eased(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return x * x * (3 - 2 * x)
    }

    /// The leading `progress` of `path`, with the tip interpolated between the
    /// two samples it falls between. Without that interpolation the head
    /// advances one whole sample per frame and the draw visibly steps — a
    /// 64-sample arc over a second is barely a sample per frame.
    static func drawn(_ path: [CLLocationCoordinate2D],
                      to progress: Double) -> [CLLocationCoordinate2D] {
        guard path.count >= 2 else { return [] }
        let clamped = min(1, max(0, progress))
        if clamped >= 1 { return path }
        let scaled = clamped * Double(path.count - 1)
        let index = min(path.count - 2, Int(scaled))
        let fraction = scaled - Double(index)
        var drawn = Array(path[0...index])
        if fraction > 0 {
            let a = path[index], b = path[index + 1]
            // Longitude interpolates the SHORT way round, so a route crossing
            // the date line grows across it rather than unwinding the whole
            // globe for one frame.
            var deltaLon = b.longitude - a.longitude
            if deltaLon > 180 { deltaLon -= 360 } else if deltaLon < -180 { deltaLon += 360 }
            // …and the result is folded back into the world, so the tip is
            // a legal coordinate on the frames between the two samples that
            // straddle the line, not 181° for a frame.
            var lon = a.longitude + deltaLon * fraction
            if lon > 180 { lon -= 360 } else if lon < -180 { lon += 360 }
            drawn.append(CLLocationCoordinate2D(
                latitude: a.latitude + (b.latitude - a.latitude) * fraction,
                longitude: lon))
        }
        return drawn
    }
}
