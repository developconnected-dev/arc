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
        for (index, token) in tokens.enumerated() where index + 1 < tokens.count {
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

        // Day + month name in either order, with or without an ordinal suffix.
        guard let monthName = months.keys.first(where: { upper.contains($0) }),
              let month = months[monthName] else { return nil }
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
}
