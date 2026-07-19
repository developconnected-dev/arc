import Foundation

/// Loads bundled airport + airline reference data and answers prefix searches
/// used by Add-Flight typeahead. Loaded once, cached in memory.
final class ReferenceData: Sendable {
    static let shared = ReferenceData()

    let airports: [AirportRef]
    let airlines: [AirlineRef]
    private let airportByIATA: [String: AirportRef]
    private let airlineByIATA: [String: AirlineRef]

    private init() {
        let ap: [AirportRef] = Self.decode("airports.json") ?? []
        let al: [AirlineRef] = Self.decode("airlines.json") ?? []
        self.airports = ap
        self.airlines = al
        self.airportByIATA = Dictionary(ap.map { ($0.iata, $0) }, uniquingKeysWith: { a, _ in a })
        self.airlineByIATA = Dictionary(al.map { ($0.iata, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Test seam: load from explicit arrays instead of the bundle.
    init(airports: [AirportRef], airlines: [AirlineRef]) {
        self.airports = airports
        self.airlines = airlines
        self.airportByIATA = Dictionary(airports.map { ($0.iata, $0) }, uniquingKeysWith: { a, _ in a })
        self.airlineByIATA = Dictionary(airlines.map { ($0.iata, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private static func decode<T: Decodable>(_ name: String) -> T? {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: base, withExtension: ext),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func airport(_ iata: String) -> AirportRef? { airportByIATA[iata.uppercased()] }
    func airline(_ iata: String) -> AirlineRef? { airlineByIATA[iata.uppercased()] }
    func timezone(_ iata: String) -> TimeZone? {
        guard let tz = airport(iata)?.tz, let z = TimeZone(identifier: tz) else { return nil }
        return z
    }

    /// Airports matching a query by IATA / city / name prefix. IATA-exact first.
    func searchAirports(_ query: String, limit: Int = 12) -> [AirportRef] {
        let q = query.trimmingCharacters(in: .whitespaces).uppercased()
        guard q.count >= 1 else { return [] }
        func rank(_ a: AirportRef) -> Int {
            if a.iata == q { return 0 }
            if a.iata.hasPrefix(q) { return 1 }
            if a.city.uppercased().hasPrefix(q) { return 2 }
            if a.name.uppercased().contains(q) || a.city.uppercased().contains(q) { return 3 }
            return 99
        }
        var scored: [(AirportRef, Int)] = []
        for a in airports {
            let r = rank(a)
            if r < 99 { scored.append((a, r)) }
        }
        scored.sort { lhs, rhs in
            lhs.1 != rhs.1 ? lhs.1 < rhs.1 : lhs.0.iata < rhs.0.iata
        }
        return Array(scored.prefix(limit).map { $0.0 })
    }

    /// Airlines matching a query by IATA / ICAO / name prefix.
    func searchAirlines(_ query: String, limit: Int = 12) -> [AirlineRef] {
        let q = query.trimmingCharacters(in: .whitespaces).uppercased()
        guard q.count >= 1 else { return [] }
        func rank(_ a: AirlineRef) -> Int {
            if a.iata == q { return 0 }
            if a.icao == q { return 1 }
            if a.name.uppercased().hasPrefix(q) { return 2 }
            if a.name.uppercased().contains(q) { return 3 }
            return 99
        }
        var scored: [(AirlineRef, Int)] = []
        for a in airlines {
            let r = rank(a)
            if r < 99 { scored.append((a, r)) }
        }
        scored.sort { lhs, rhs in
            lhs.1 != rhs.1 ? lhs.1 < rhs.1 : lhs.0.name < rhs.0.name
        }
        return Array(scored.prefix(limit).map { $0.0 })
    }
}
