import Foundation

/// Whether the weather at an airport is likely to hold a flight up.
///
/// En-route hazards rarely delay anyone — aircraft route around a storm cell
/// and lose minutes. Departures are held by conditions AT the field: fog, low
/// cloud, crosswind gusts, thunderstorms overhead, snow that means de-icing.
/// So this scores the airport, from the current METAR and the TAF period
/// covering the departure, and deliberately says nothing when the weather is
/// merely unpleasant. Drizzle is not news.
///
/// Thresholds are the operational ones: IFR below 1500m visibility or a 500ft
/// ceiling, marginal below 5000m or 1000ft, and gusts that start to matter to
/// a narrowbody around 35kt.
enum DelayRisk {
    enum Level: Int, Comparable {
        case none = 0, low = 1, moderate = 2, high = 3
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .none: "Weather looks fine"
            case .low: "Minor weather"
            case .moderate: "Possible weather delay"
            case .high: "Likely weather delay"
            }
        }
    }

    struct Assessment: Equatable {
        let level: Level
        /// Plain reasons, worst first — "Fog, 700m visibility", not a METAR dump.
        let reasons: [String]
        var isWorthShowing: Bool { level >= .moderate }
    }

    /// One set of conditions, from either the observation or the forecast.
    struct Conditions: Codable, Sendable, Equatable {
        var visibilityM: Int?
        var ceilingFt: Int?
        var windKt: Int?
        var gustKt: Int?
        var windShear: Bool?
        var wx: String?
    }

    static func assess(_ c: Conditions) -> Assessment {
        var level = Level.none
        var reasons: [String] = []
        func raise(_ to: Level, _ why: String) {
            if to > level { level = to }
            reasons.append(why)
        }

        if let v = c.visibilityM {
            if v < 1500 { raise(.high, "Low visibility, \(v)m") }
            else if v < 5000 { raise(.moderate, "Reduced visibility, \(v)m") }
        }
        if let ceiling = c.ceilingFt {
            if ceiling < 500 { raise(.high, "Low cloud, \(ceiling)ft ceiling") }
            else if ceiling < 1000 { raise(.moderate, "Low cloud, \(ceiling)ft ceiling") }
        }
        if let gust = c.gustKt {
            if gust >= 45 { raise(.high, "Strong gusts, \(gust)kt") }
            else if gust >= 35 { raise(.moderate, "Gusts \(gust)kt") }
            else if gust >= 25 { raise(.low, "Breezy, gusts \(gust)kt") }
        }
        if c.windShear == true { raise(.moderate, "Wind shear reported") }

        // Present weather codes. TS is a thunderstorm over the field, which
        // stops ground handling outright; FZ/SN mean de-icing queues.
        let wx = (c.wx ?? "").uppercased()
        if wx.contains("TS") { raise(.high, "Thunderstorms at the airport") }
        if wx.contains("FZ") { raise(.high, "Freezing precipitation") }
        if wx.contains("SN") { raise(.moderate, "Snow — de-icing likely") }
        if wx.contains("FG") || wx.contains("BR"), (c.visibilityM ?? 9999) < 5000 {
            raise(.moderate, "Fog")
        }

        return Assessment(level: level, reasons: reasons)
    }

    /// The worse of "right now" and "at departure" — a field that's clear now
    /// but forecast to fog in by departure is exactly the case worth flagging.
    static func assess(now: Conditions?, atDeparture: Conditions?) -> Assessment {
        let candidates = [now, atDeparture].compactMap { $0 }.map(assess)
        guard let worst = candidates.max(by: { $0.level < $1.level }) else {
            return Assessment(level: .none, reasons: [])
        }
        return worst
    }
}
