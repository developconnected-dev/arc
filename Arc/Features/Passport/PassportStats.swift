import Foundation

/// Aggregate lifetime (or per-year) statistics computed from completed flights.
struct PassportStats {
    let flights: Int
    let longHaul: Int
    let distanceKm: Double
    let seconds: TimeInterval
    let airports: Int
    let airlines: Int
    let delayMinutesLost: Int
    let delayedFlights: Int
    let mostFlownAircraft: String?
    let mostFlownCount: Int

    init(_ flights: [Flight]) {
        let done = flights.filter { $0.status == .landed }
        self.flights = done.count
        self.longHaul = done.filter { $0.distanceKm > 4000 }.count
        self.distanceKm = done.map(\.distanceKm).reduce(0, +)
        self.seconds = done.map(\.duration).reduce(0, +)
        // Codes and airline identities are aviation facts — a rail leg's "BER"
        // is Berlin Hbf, not an airport visited, and a rail operator is not an
        // airline flown.
        var apts = Set<String>()
        for f in done where f.mode == .air { apts.insert(f.departureIATA); apts.insert(f.arrivalIATA) }
        self.airports = apts.count
        self.airlines = Set(done.filter { $0.mode == .air }.map(\.airlineCode)).count
        // Delay stats only from legs whose source reported punctuality — the
        // widget already zeroes these out for timetable/manual tiers, and the
        // passport must not count what nobody measured.
        let delayed = done.filter { $0.delayMinutes > 0 && $0.dataTier.reportsPunctuality }
        self.delayedFlights = delayed.count
        self.delayMinutesLost = delayed.map(\.delayMinutes).reduce(0, +)
        let byType = Dictionary(grouping: done.compactMap { $0.aircraftType }, by: { $0 })
            .mapValues(\.count).sorted { $0.value > $1.value }
        self.mostFlownAircraft = byType.first?.key
        self.mostFlownCount = byType.first?.value ?? 0
    }

    var distanceFormatted: String {
        let s = NumberFormatter()
        s.groupingSeparator = "'"; s.numberStyle = .decimal; s.maximumFractionDigits = 0
        return (s.string(from: NSNumber(value: distanceKm)) ?? "\(Int(distanceKm))") + " km"
    }
    var aroundWorld: String { String(format: "%.1fx around the world", distanceKm / 40075.0) }
    var flightTimeFormatted: String {
        let h = Int(seconds) / 3600, m = (Int(seconds) % 3600) / 60
        return "\(h)h \(m)m"
    }
    var avgDelay: Int { delayedFlights > 0 ? delayMinutesLost / delayedFlights : 0 }
}

extension Flight {
    /// Short aircraft code for a tag pill, e.g. "Airbus A321neo" → "A321neo".
    var aircraftShort: String? {
        guard let t = aircraftType else { return nil }
        let tokens = t.split(separator: " ")
        if let model = tokens.first(where: { tok in
            let u = tok.uppercased()
            return (u.first == "A" || u.first == "B" || u.first == "E") && u.dropFirst().first?.isNumber == true
        }) { return String(model) }
        return tokens.last.map(String.init)
    }
}
