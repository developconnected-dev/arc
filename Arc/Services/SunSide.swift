import Foundation
import CoreLocation

/// Which side of the aircraft the sun will be on — computed from the route and
/// the clock, using the same low-precision solar math as the map's terminator.
/// A window-seat tip doesn't need arcminutes; it needs to be right about left
/// versus right, and to say nothing when the answer is genuinely mixed.
enum SunSide {

    struct Tip: Equatable {
        let icon: String
        let title: String
        let detail: String
    }

    /// Sun azimuth and elevation at a point and instant. Elevation falls out
    /// of the geometry for free: it's 90° minus the great-circle distance to
    /// the subsolar point.
    static func sunPosition(at p: CLLocationCoordinate2D, date: Date) -> (azimuth: Double, elevation: Double) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let day = Double(cal.ordinality(of: .day, in: .year, for: date) ?? 172)
        let comps = cal.dateComponents([.hour, .minute], from: date)
        let hours = Double(comps.hour ?? 12) + Double(comps.minute ?? 0) / 60

        let decl = -23.44 * cos(2 * .pi * (day + 10) / 365)
        var subLon = -15.0 * (hours - 12.0)
        while subLon > 180 { subLon -= 360 }
        while subLon < -180 { subLon += 360 }
        let sub = CLLocationCoordinate2D(latitude: decl, longitude: subLon)

        let azimuth = GeoMath.bearing(from: p, to: sub)
        let elevation = 90 - angularDistance(p, sub)
        return (azimuth, elevation)
    }

    /// Which side a sun at `sunAzimuth` sits on for an aircraft flying
    /// `course`. Nil when it's close to dead ahead or dead astern — nobody's
    /// window wins those.
    static func side(course: Double, sunAzimuth: Double) -> String? {
        var rel = (sunAzimuth - course).truncatingRemainder(dividingBy: 360)
        if rel < 0 { rel += 360 }
        if rel > 15 && rel < 165 { return "right" }
        if rel > 195 && rel < 345 { return "left" }
        return nil
    }

    /// The tip for a route and time window, or nil when there's nothing worth
    /// saying. Sampled at three points along the great circle; the tip only
    /// speaks when at least two daylight samples agree.
    static func tip(dep: CLLocationCoordinate2D, arr: CLLocationCoordinate2D,
                    departure: Date, arrival: Date) -> Tip? {
        guard arrival > departure,
              abs(dep.latitude) + abs(dep.longitude) > 0.01,
              abs(arr.latitude) + abs(arr.longitude) > 0.01 else { return nil }

        let path = GeoMath.greatCircle(from: dep, to: arr, samples: 20)
        guard path.count > 2 else { return nil }
        let duration = arrival.timeIntervalSince(departure)

        func sample(_ f: Double) -> (point: CLLocationCoordinate2D, course: Double, sun: (azimuth: Double, elevation: Double)) {
            let i = min(path.count - 2, max(0, Int(f * Double(path.count - 1))))
            let point = path[i]
            let course = GeoMath.bearing(from: path[i], to: path[i + 1])
            let sun = sunPosition(at: point, date: departure.addingTimeInterval(duration * f))
            return (point, course, sun)
        }

        var lefts = 0, rights = 0, daylight = 0
        for f in [0.2, 0.5, 0.8] {
            let s = sample(f)
            guard s.sun.elevation > -1 else { continue }   // night sample
            daylight += 1
            switch side(course: s.course, sunAzimuth: s.sun.azimuth) {
            case "left": lefts += 1
            case "right": rights += 1
            default: break
            }
        }

        // Flying into darkness is its own tip — sunset from a window seat.
        let startsInDay = sample(0.05).sun.elevation > 0
        let endsInNight = sample(0.95).sun.elevation < -1

        if daylight == 0 {
            return Tip(icon: "moon.stars.fill", title: "Night flight",
                       detail: "Dark the whole way — window seats get city lights and, with luck, stars.")
        }
        if startsInDay && endsInNight {
            let side = rights >= 2 ? " on the right" : lefts >= 2 ? " on the left" : ""
            return Tip(icon: "sun.horizon.fill", title: "You'll fly into the sunset",
                       detail: "Daylight fades en route — the show is\(side.isEmpty ? " out the window" : side).")
        }
        if rights >= 2 {
            return Tip(icon: "sun.max.fill", title: "Sun on the right side",
                       detail: "Sit on the left for shade, on the right for the views.")
        }
        if lefts >= 2 {
            return Tip(icon: "sun.max.fill", title: "Sun on the left side",
                       detail: "Sit on the right for shade, on the left for the views.")
        }
        return nil
    }

    private static func angularDistance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let hav = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * asin(min(1, sqrt(hav))) * 180 / .pi
    }
}
