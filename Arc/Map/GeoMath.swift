import Foundation
import CoreLocation
import MapKit

enum GeoMath {
    /// A rhumb line (constant bearing) from a to b, densified so `position(along:)`
    /// can walk it. This is what a ship actually steers and what a sea chart
    /// draws — a straight line on the Mercator map — as opposed to the great
    /// circle an aircraft flies, which bows poleward and is how a flight is
    /// recognised on this map. Drawing a sailing as an arc made it read as a
    /// flight; the geometry itself is the first cue that it isn't one.
    static func rhumbLine(from a: CLLocationCoordinate2D,
                          to b: CLLocationCoordinate2D,
                          samples: Int = 32) -> [CLLocationCoordinate2D] {
        let n = max(2, samples)
        // Interpolate in Mercator space so the result is straight ON THE MAP.
        func merc(_ lat: Double) -> Double { log(tan(.pi / 4 + (lat * .pi / 180) / 2)) }
        func unmerc(_ y: Double) -> Double { (2 * atan(exp(y)) - .pi / 2) * 180 / .pi }
        var dLon = b.longitude - a.longitude
        if dLon > 180 { dLon -= 360 } else if dLon < -180 { dLon += 360 }
        let y1 = merc(a.latitude), y2 = merc(b.latitude)
        return (0...n).map { i in
            let f = Double(i) / Double(n)
            return .init(latitude: unmerc(y1 + (y2 - y1) * f),
                         longitude: a.longitude + dLon * f)
        }
    }

    /// Samples `samples` intermediate points along the great circle from a to b
    /// (inclusive of both endpoints) so a MapPolyline renders a curved arc.
    static func greatCircle(from a: CLLocationCoordinate2D,
                            to b: CLLocationCoordinate2D,
                            samples: Int = 64) -> [CLLocationCoordinate2D] {
        let n = max(2, samples)
        let lat1 = a.latitude * .pi / 180, lon1 = a.longitude * .pi / 180
        let lat2 = b.latitude * .pi / 180, lon2 = b.longitude * .pi / 180
        let dLat = lat2 - lat1, dLon = lon2 - lon1
        let hav = sin(dLat/2)*sin(dLat/2) + cos(lat1)*cos(lat2)*sin(dLon/2)*sin(dLon/2)
        let d = 2 * asin(min(1, sqrt(hav)))
        guard d > 1e-9 else { return [a, b] }
        var pts: [CLLocationCoordinate2D] = []
        for i in 0...n {
            let f = Double(i) / Double(n)
            let A = sin((1-f)*d) / sin(d)
            let B = sin(f*d) / sin(d)
            let x = A*cos(lat1)*cos(lon1) + B*cos(lat2)*cos(lon2)
            let y = A*cos(lat1)*sin(lon1) + B*cos(lat2)*sin(lon2)
            let z = A*sin(lat1) + B*sin(lat2)
            let lat = atan2(z, sqrt(x*x + y*y))
            let lon = atan2(y, x)
            pts.append(.init(latitude: lat*180/(.pi), longitude: lon*180/(.pi)))
        }
        return pts
    }

    /// A region that fits all given coordinates with padding, clamped to sane spans.
    static func region(fitting coords: [CLLocationCoordinate2D],
                       paddingFactor: Double = 1.4) -> MKCoordinateRegion? {
        guard !coords.isEmpty else { return nil }
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!
        let center = CLLocationCoordinate2D(latitude: (minLat+maxLat)/2, longitude: (minLon+maxLon)/2)
        let span = MKCoordinateSpan(
            latitudeDelta: max(2, (maxLat-minLat) * paddingFactor),
            longitudeDelta: max(2, (maxLon-minLon) * paddingFactor)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    // MARK: - Pillar 2.1: Day/Night Solar Terminator Shadow & Live Weather Corridors

    struct FlightWeatherCorridor: Identifiable {
        let id = UUID()
        let coordinate: CLLocationCoordinate2D
        let radiusMeters: Double
        let isStorm: Bool
        let label: String
    }

    /// Computes the closed coordinates for the night-hemisphere solar shadow on Earth.
    static func solarTerminatorPolygon(date: Date = .now) -> [CLLocationCoordinate2D] {
        let cal = Calendar.current
        let dayOfYear = Double(cal.ordinality(of: .day, in: .year, for: date) ?? 180)
        let comps = cal.dateComponents([.hour, .minute, .second], from: date)
        let utcHours = Double(comps.hour ?? 12) + Double(comps.minute ?? 0)/60.0

        // Solar declination approx (radians)
        let declDeg = -23.44 * cos((360.0 / 365.25 * (dayOfYear + 10.0)) * .pi / 180.0)
        let decl = declDeg * .pi / 180.0

        // Subsolar longitude (degrees)
        let subsolarLon = -15.0 * (utcHours - 12.0)

        var terminator: [CLLocationCoordinate2D] = []
        let lonStep: Double = 5.0
        for lon in stride(from: -180.0, through: 180.0, by: lonStep) {
            let dLon = (lon - subsolarLon) * .pi / 180.0
            // tan(lat) = -cos(dLon) / tan(decl)
            let tanLat = -cos(dLon) / max(0.0001, tan(decl))
            let latRad = atan(tanLat)
            var latDeg = latRad * 180.0 / .pi
            latDeg = max(-89.9, min(89.9, latDeg))
            terminator.append(.init(latitude: latDeg, longitude: lon))
        }

        // Close around the pole in darkness
        let nightPole: Double = declDeg >= 0 ? -89.9 : 89.9
        for lon in stride(from: 180.0, through: -180.0, by: -lonStep) {
            terminator.append(.init(latitude: nightPole, longitude: lon))
        }

        return terminator
    }

    /// Published hazards whose polygon comes near this route.
    ///
    /// Filtering matters as much as fetching: there are ~160 live advisories
    /// worldwide, and drawing all of them would bury the flight. A hazard is
    /// relevant when any of its vertices falls within `withinKm` of the
    /// great-circle track.
    static func hazards(_ all: [FlightAPIClient.WeatherHazard],
                        near dep: CLLocationCoordinate2D,
                        to arr: CLLocationCoordinate2D,
                        withinKm: Double = 300) -> [FlightAPIClient.WeatherHazard] {
        let track = greatCircle(from: dep, to: arr, samples: 24)
        guard !track.isEmpty else { return [] }
        return all.filter { hazard in
            hazard.coords.contains { vertex in
                track.contains { point in
                    distanceKm(CLLocationCoordinate2D(latitude: vertex.lat, longitude: vertex.lon),
                               point) <= withinKm
                }
            }
        }
    }

    /// Where along a route something is at `progress` (0…1), plus the heading it
    /// is travelling on.
    ///
    /// This is what lets an airborne flight show a plane without a live fix.
    /// ADS-B is free but frequently silent — OpenSky returns `states: null` for
    /// plenty of aircraft even when reachable — so a live-only plane vanishes
    /// mid-flight for reasons the user can't see. Clock math always works, needs
    /// no network, and is right to within a few miles on a great circle.
    static func position(along route: [CLLocationCoordinate2D],
                         progress: Double) -> (coordinate: CLLocationCoordinate2D, heading: Double)? {
        guard route.count >= 2 else { return nil }
        let clamped = min(1, max(0, progress))
        let index = min(route.count - 1, max(0, Int(clamped * Double(route.count - 1))))
        let here = route[index]
        // Heading from the neighbouring sample, so the icon points along the arc.
        let next = route[min(route.count - 1, index + 1)]
        let prev = route[max(0, index - 1)]
        return (here, bearing(from: index == route.count - 1 ? prev : here,
                              to: index == route.count - 1 ? here : next))
    }

    /// Initial great-circle bearing in degrees, 0 = north.
    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }

    /// Rough centre of a polygon — good enough to hang one label off, which is
    /// all this is used for.
    static func centroid(_ points: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
        guard !points.isEmpty else { return nil }
        let lat = points.reduce(0.0) { $0 + $1.latitude } / Double(points.count)
        let lon = points.reduce(0.0) { $0 + $1.longitude } / Double(points.count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Great-circle distance in kilometres.
    static func distanceKm(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let r = 6371.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    @available(*, deprecated, message: "Synthetic: derived hazards from the flight number's hash. Use hazards(_:near:to:).")
    static func generateWeatherCorridors(from dep: CLLocationCoordinate2D, to arr: CLLocationCoordinate2D, code: String) -> [FlightWeatherCorridor] {
        let gc = greatCircle(from: dep, to: arr, samples: 20)
        guard gc.count > 10 else { return [] }
        
        let hash = abs(code.hashValue)
        var corridors: [FlightWeatherCorridor] = []
        
        // Storm cell at ~35% of route
        let stormPt = gc[gc.count * 35 / 100]
        let stormAlt = 320 + (hash % 60)
        corridors.append(FlightWeatherCorridor(
            coordinate: stormPt,
            radiusMeters: Double(70_000 + (hash % 30_000)),
            isStorm: true,
            label: "⛈️ Storm Cell • FL\(stormAlt)"
        ))
        
        // Jet stream wind cell at ~70% of route
        let windPt = gc[gc.count * 70 / 100]
        let windSpeed = 65 + (hash % 45)
        corridors.append(FlightWeatherCorridor(
            coordinate: windPt,
            radiusMeters: Double(110_000 + (hash % 40_000)),
            isStorm: false,
            label: "💨 Jet Stream • +\(windSpeed)kt"
        ))
        
        return corridors
    }
}
