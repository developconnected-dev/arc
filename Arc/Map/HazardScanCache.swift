import Foundation
import CoreLocation

/// Which published advisories sit near which routes — answered from memory
/// for the same inputs.
///
/// The scan is a few hundred thousand distance checks (every advisory
/// vertex against 24 samples of every route), and the map's body asks for
/// it on every rebuild: the minute tick, any status change, and sixty times
/// a second while a freshly added route draws itself on. The advisories
/// change once per fetch and the routes once per list change, so the answer
/// is the same almost every time it is asked for.
struct HazardScanCache {
    /// How many times the scan has actually run — the number the tests
    /// watch, and an honest count for anyone profiling the map.
    private(set) var scans = 0
    private var key: Int?
    private var cached: [FlightAPIClient.WeatherHazard] = []

    mutating func hazards(_ all: [FlightAPIClient.WeatherHazard],
                          routes: [(CLLocationCoordinate2D, CLLocationCoordinate2D)]) -> [FlightAPIClient.WeatherHazard] {
        guard !all.isEmpty, !routes.isEmpty else { return [] }
        var hasher = Hasher()
        hasher.combine(all.count)
        for hazard in all {
            hasher.combine(hazard.id)
            hasher.combine(hazard.coords.count)
        }
        hasher.combine(routes.count)
        for (dep, arr) in routes {
            hasher.combine(dep.latitude); hasher.combine(dep.longitude)
            hasher.combine(arr.latitude); hasher.combine(arr.longitude)
        }
        let key = hasher.finalize()
        if key == self.key { return cached }

        scans += 1
        var seen = Set<String>()
        var out: [FlightAPIClient.WeatherHazard] = []
        for (dep, arr) in routes {
            for hazard in GeoMath.hazards(all, near: dep, to: arr) where seen.insert(hazard.id).inserted {
                out.append(hazard)
            }
        }
        self.key = key
        cached = out
        return out
    }
}
