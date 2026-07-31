import Foundation

/// Turns one free-text box into a flight lookup: "A31653 on the 18th of
/// September", "Swiss 1413 tomorrow", "LX8", or a pasted confirmation.
///
/// Runs locally first so the common case is instant, offline and free; only
/// text this can't resolve is worth sending to the AI parser.
enum FlightQueryParser {
    struct Query: Equatable {
        let code: String        // normalised, e.g. "A31653"
        let date: Date?         // nil = caller decides (today)
    }

    /// Splits a designator from its number.
    ///
    /// Splitting on "everything before the first digit" turned A31653 into
    /// airline "A" + flight "31653", which then resolved to a different airline
    /// entirely. A designator is two alphanumerics (IATA — A3, 4U, U2, 6E) or
    /// three letters (ICAO), never "letters up to the first digit".
    static func splitCode(_ raw: String) -> (designator: String, number: String)? {
        let cleaned = raw.uppercased().replacingOccurrences(of: " ", with: "")
        guard cleaned.range(of: "^(?=.*[A-Z])([A-Z]{3}|[A-Z0-9]{2})\\d{1,4}$",
                            options: .regularExpression) != nil else { return nil }
        // Three leading letters means ICAO; otherwise the designator is 2 chars.
        let letters = cleaned.prefix(3)
        let isICAO = letters.count == 3 && letters.allSatisfy(\.isLetter)
        let split = isICAO ? 3 : 2
        let designator = String(cleaned.prefix(split))
        let number = String(cleaned.dropFirst(split))
        guard !number.isEmpty else { return nil }
        return (designator, number)
    }

    /// A flight code anywhere in the text — "…September A31653" included.
    static func findCode(in text: String) -> String? {
        let upper = text.uppercased()
        // Scan word-like runs rather than one regex over the whole string, so a
        // date such as "18TH" can't be mistaken for a designator plus number.
        let tokens = upper.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        for token in tokens where splitCode(token) != nil {
            return token
        }
        // "Swiss 1413" / "LX 1413": a name or designator, then a separate number.
        // Ordinary English words are never meant as designators, even when an
        // airline holds that IATA — "on 18 September" is not Nauru Airlines ON18.
        let stopwords: Set<String> = ["ON", "TO", "IN", "AT", "OF", "THE", "AND",
                                      "OR", "FOR", "BY", "FROM", "A", "AN", "MY"]
        for (index, token) in tokens.enumerated() where index + 1 < tokens.count {
            guard !stopwords.contains(token) else { continue }
            let next = tokens[index + 1]
            guard next.allSatisfy(\.isNumber), next.count <= 4 else { continue }
            if let airline = ReferenceData.shared.airline(token)
                ?? ReferenceData.shared.searchAirlines(token).first {
                return "\(airline.iata)\(next)"
            }
        }
        return nil
    }

    private static let months = ["JANUARY": 1, "FEBRUARY": 2, "MARCH": 3, "APRIL": 4,
                                 "MAY": 5, "JUNE": 6, "JULY": 7, "AUGUST": 8,
                                 "SEPTEMBER": 9, "OCTOBER": 10, "NOVEMBER": 11, "DECEMBER": 12]

    /// A date from ordinary phrasing. Bare day-and-month with no year resolves
    /// to the next time it occurs, so "18 September" typed in December means
    /// next year rather than a date already past.
    static func findDate(in text: String, now: Date) -> Date? {
        let upper = text.uppercased()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        if upper.contains("TOMORROW") { return calendar.date(byAdding: .day, value: 1, to: now) }
        if upper.contains("TODAY") || upper.contains("TONIGHT") { return now }
        if upper.contains("DAY AFTER") { return calendar.date(byAdding: .day, value: 2, to: now) }

        if let iso = upper.range(of: "\\d{4}-\\d{2}-\\d{2}", options: .regularExpression) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_GB")
            f.dateFormat = "yyyy-MM-dd"
            if let d = f.date(from: String(upper[iso])) { return d }
        }

        // Swiss/European numeric dates: "18.9.", "18.09.2026".
        if let match = upper.firstMatch(of: /(\d{1,2})\.(\d{1,2})(?:\.(\d{2,4}))?/),
           let day = Int(match.1), let month = Int(match.2),
           (1...31).contains(day), (1...12).contains(month) {
            var year = match.3.flatMap { Int($0) } ?? calendar.component(.year, from: now)
            if year < 100 { year += 2000 }
            var parts = DateComponents(year: year, month: month, day: day, hour: 12)
            if let candidate = calendar.date(from: parts) {
                if match.3 == nil, candidate < calendar.startOfDay(for: now) {
                    parts.year = year + 1
                    return calendar.date(from: parts)
                }
                return candidate
            }
        }

        // Day + month name in either order, abbreviated ("18 Sep") or full,
        // with or without an ordinal suffix.
        let wordTokens = upper.components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 3 }
        guard let month = wordTokens.lazy
            .compactMap({ t in months.first(where: { $0.key.hasPrefix(t) })?.value })
            .first else { return nil }
        let tokens = upper.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .filter { !$0.isEmpty }
        guard let day = tokens.compactMap({ Int($0) }).first(where: { $0 >= 1 && $0 <= 31 })
        else { return nil }

        let year = calendar.component(.year, from: now)
        var parts = DateComponents(year: year, month: month, day: day, hour: 12)
        guard let candidate = calendar.date(from: parts) else { return nil }
        if candidate < calendar.startOfDay(for: now) {
            parts.year = year + 1
            return calendar.date(from: parts)
        }
        return candidate
    }

    static func parse(_ text: String, now: Date = .now) -> Query? {
        guard let code = findCode(in: text) else { return nil }
        return Query(code: code, date: findDate(in: text, now: now))
    }

    // MARK: - Route queries ("Athens to Munich 18 September")

    struct RouteQuery: Equatable {
        let depIATA: String
        let arrIATA: String
        let date: Date?
    }

    /// Cities that are ambiguous by name — namesakes on other continents
    /// (Athens, Georgia) or metros with several airports — resolved to the
    /// airport a flight search means by default. Same single-airport choice
    /// the AI parser makes, without the AI.
    private static let primaryAirport: [String: String] = [
        "ATHENS": "ATH", "LONDON": "LHR", "PARIS": "CDG", "MILAN": "MXP",
        "ROME": "FCO", "NEW YORK": "JFK", "ISTANBUL": "IST", "MOSCOW": "SVO",
        "TOKYO": "HND", "OSAKA": "KIX", "BANGKOK": "BKK", "SAO PAULO": "GRU",
        "BUENOS AIRES": "EZE", "WASHINGTON": "IAD", "CHICAGO": "ORD",
        "HOUSTON": "IAH", "DUBAI": "DXB", "SHANGHAI": "PVG", "BEIJING": "PEK",
        "SEOUL": "ICN", "STOCKHOLM": "ARN", "OSLO": "OSL", "BERLIN": "BER",
        "MONTREAL": "YUL", "TORONTO": "YYZ", "SAN FRANCISCO": "SFO",
        "LOS ANGELES": "LAX", "BRUSSELS": "BRU", "BUCHAREST": "OTP",
    ]

    private static let leftNoise: Set<String> = [
        "ADD", "SEARCH", "FIND", "SHOW", "ME", "A", "AN", "THE",
        "FLIGHT", "FLIGHTS", "FROM", "PLEASE",
    ]

    private static func isDateish(_ token: String) -> Bool {
        if token.first?.isNumber == true { return true }
        if ["ON", "TOMORROW", "TODAY", "TONIGHT", "NEXT", "THIS"].contains(token) { return true }
        return token.count >= 3 && months.keys.contains { $0.hasPrefix(token) }
    }

    private static func resolveAirport(_ name: String) -> AirportRef? {
        guard !name.isEmpty else { return nil }
        let ref = ReferenceData.shared
        if name.count == 3, let a = ref.airport(name) { return a }
        if let primary = primaryAirport[name], let a = ref.airport(primary) { return a }
        let cityMatches = ref.airports.filter { $0.city.uppercased() == name }
        if cityMatches.count == 1 { return cityMatches[0] }
        // Namesake cities: exactly one "International" airport is decisive.
        let intl = cityMatches.filter { $0.name.uppercased().contains("INTERNATIONAL") }
        return intl.count == 1 ? intl[0] : nil
    }

    /// "Athens to Munich 18 September" resolved locally — no AI, no network.
    /// Answers only when both endpoints resolve unambiguously; everything
    /// else stays with the server-side AI parser.
    static func parseRoute(_ text: String, now: Date = .now) -> RouteQuery? {
        // A recognisable flight number means this is not a route query.
        guard findCode(in: text) == nil else { return nil }
        let upper = text.uppercased()
        guard let toRange = upper.range(of: " TO ") else { return nil }

        func tokens(_ s: Substring) -> [String] {
            s.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        let depTokens = tokens(upper[..<toRange.lowerBound]).filter { !leftNoise.contains($0) }
        var arrTokens: [String] = []
        for t in tokens(upper[toRange.upperBound...]) {
            if isDateish(t) { break }
            arrTokens.append(t)
        }

        guard let dep = resolveAirport(depTokens.joined(separator: " ")),
              let arr = resolveAirport(arrTokens.joined(separator: " ")),
              dep.iata != arr.iata else { return nil }
        return RouteQuery(depIATA: dep.iata, arrIATA: arr.iata, date: findDate(in: text, now: now))
    }
}
