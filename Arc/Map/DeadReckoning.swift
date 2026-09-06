import Foundation
import CoreLocation

/// Where an aircraft is right now, on one rule for every surface that asks.
struct PlanePosition: Equatable {
    let coordinate: CLLocationCoordinate2D
    /// Degrees, 0 = north.
    let heading: Double
    /// A fresh sighting rather than a reckoning — drawn at full "this is
    /// real" opacity. The position itself is continuous across this flag.
    let isLive: Bool
    /// How far along the path ahead of the anchor the estimate sits, 0…1.
    let fraction: Double

    static func == (a: Self, b: Self) -> Bool {
        a.coordinate.latitude == b.coordinate.latitude
            && a.coordinate.longitude == b.coordinate.longitude
            && a.heading == b.heading && a.isLive == b.isLive && a.fraction == b.fraction
    }
}

/// Dead reckoning from the last sighting, paced by the ETA.
///
/// The map used to answer "where is the plane" twice: the flown line ended
/// at the last live fix however old it was, and the glyph trusted a fix for
/// fifteen minutes then jumped to the clock's place on the planned arc. The
/// moment a long-haul left ADS-B coverage over the ocean, the plane
/// visibly detached from its own track.
///
/// One rule instead. Start from the last place the aircraft was really
/// seen — the live fix, else the newest breadcrumb, else the departure
/// airport at the moment it left — and move along the route still ahead by
/// the share of time elapsed between that sighting and the estimated
/// arrival. The estimate is exactly on a fix at the instant of the fix and
/// glides on from it, so the correction when coverage returns is small; it
/// reaches the airport dot exactly when the arrival countdown ends; and a
/// fix that goes stale changes how the plane is DRAWN, never where it is.
enum DeadReckoning {
    /// How long a sighting is drawn as "this is real". Same window every
    /// surface uses for a live fix.
    static let freshWindow: TimeInterval = 15 * 60

    /// The last place and time the aircraft was actually seen — or where it
    /// started, at the moment it left, when it never was.
    struct Anchor {
        let coordinate: CLLocationCoordinate2D
        let at: Date
        /// The transponder's heading, when the anchor is a fix that had one.
        let heading: Double?
        /// A real sighting (fix or breadcrumb) rather than the departure gate.
        let isSighting: Bool
    }

    /// The aircraft's position at `now`, reckoned from `anchor` along
    /// `remaining` — the path from the anchor to the arrival airport, in
    /// the mode's own geometry — so that it reaches the end at `eta`.
    static func position(anchor: Anchor,
                         remaining: [CLLocationCoordinate2D],
                         eta: Date,
                         now: Date) -> PlanePosition? {
        guard remaining.count >= 2 else { return nil }
        let window = eta.timeIntervalSince(anchor.at)
        let elapsed = now.timeIntervalSince(anchor.at)
        // Past its ETA and still up: hold at the airport rather than
        // overshoot. A fix stamped later than the clock: hold on the fix.
        let fraction = window <= 0 ? 1 : min(1, max(0, elapsed / window))

        let drawn = RouteReveal.drawn(remaining, to: fraction)
        guard let here = drawn.last else { return nil }
        let isLive = anchor.isSighting && elapsed < freshWindow

        let heading: Double
        if isLive, let reported = anchor.heading {
            // The transponder knows better than our geometry, while it is
            // recent enough to be believed.
            heading = reported
        } else if drawn.count >= 2 {
            heading = GeoMath.bearing(from: drawn[drawn.count - 2], to: here)
        } else {
            heading = GeoMath.bearing(from: here, to: remaining[1])
        }
        return PlanePosition(coordinate: here, heading: heading, isLive: isLive, fraction: fraction)
    }
}

extension Flight {
    /// The last place and time this aircraft was actually seen: the live
    /// fix or the newest breadcrumb, whichever is later. nil when it never was.
    var lastSighting: DeadReckoning.Anchor? {
        var best: DeadReckoning.Anchor?
        if let lat = liveLat, let lon = liveLon, let at = liveUpdatedAt {
            best = .init(coordinate: .init(latitude: lat, longitude: lon), at: at,
                         heading: liveHeading, isSighting: true)
        }
        if let crumb = trackPoints.last, best.map({ crumb.timestamp > $0.at }) ?? true {
            best = .init(coordinate: .init(latitude: crumb.lat, longitude: crumb.lon),
                         at: crumb.timestamp, heading: nil, isSighting: true)
        }
        return best
    }

    /// The path still ahead of `from`, to the arrival airport, in this
    /// leg's own geometry: a flight's arc, a sailing's rhumb line, and a
    /// train's real rails from the nearest point on them — never an arc
    /// between a station and the terminus.
    func remainingPath(from here: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        let arr = CLLocationCoordinate2D(latitude: arrivalLat, longitude: arrivalLon)
        let rails = routePath.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        guard rails.count >= 3 else {
            return ArcMapView.RouteStyle(mode: mode).path(from: here, to: arr)
        }
        var nearest = 0
        var best = Double.infinity
        for (index, sample) in rails.enumerated() {
            let d = GeoMath.distanceKm(sample, here)
            if d < best { best = d; nearest = index }
        }
        let ahead = rails[min(rails.count - 1, nearest + 1)...]
        return [here] + ahead
    }

    /// Where this aircraft is at `now`, on the one rule — see `DeadReckoning`.
    /// nil when the leg has no coordinates to reckon between.
    func planePosition(now: Date = .now) -> PlanePosition? {
        guard departureLat != 0, arrivalLat != 0 else { return nil }
        let delay = Double(delayMinutes) * 60
        let eta = estimatedArrival ?? scheduledArrival.addingTimeInterval(delay)
        let anchor = lastSighting ?? DeadReckoning.Anchor(
            coordinate: .init(latitude: departureLat, longitude: departureLon),
            at: actualDeparture ?? scheduledDeparture.addingTimeInterval(delay),
            heading: nil, isSighting: false)
        return DeadReckoning.position(anchor: anchor,
                                      remaining: remainingPath(from: anchor.coordinate),
                                      eta: eta, now: now)
    }
}
