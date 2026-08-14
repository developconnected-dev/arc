import Foundation

enum DateHelpers {
    // ISO8601DateFormatter is documented thread-safe for concurrent reads once
    // configured; these are configured once here and never mutated again, so
    // `nonisolated(unsafe)` is a correct opt-out of Swift 6's Sendable check
    // (the formatter type itself predates Sendable and can't conform).
    nonisolated(unsafe) private static let isoWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parses an ISO-8601 timestamp from the backend. AeroDataBox (via the
    /// Worker's `toISO()`, which round-trips through JS `Date.toISOString()`)
    /// always includes fractional seconds — e.g. "2026-07-20T11:05:00.000Z" —
    /// which a formatter configured with only `.withInternetDateTime` silently
    /// fails to parse. Try fractional first, fall back to plain for safety.
    static func parseAPIDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return isoWithFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    /// The calendar date of `date` AT THE GIVEN AIRPORT, as "yyyy-MM-dd" — the
    /// form AeroDataBox's by-number and by-registration endpoints expect.
    /// Formatting the instant in UTC instead (what `.iso8601` does) shifts a
    /// 00:30 CEST departure onto the PREVIOUS day: every poll then fetches
    /// yesterday's leg of the same number and stamps its landed status and
    /// times onto a flight that hasn't boarded yet.
    static func apiDate(_ date: Date, at iata: String?) -> String {
        apiDate(date, in: iata.flatMap { ReferenceData.shared.timezone($0) } ?? .current)
    }

    /// The same calendar date for a leg whose endpoint is not an airport.
    ///
    /// A station or port must never be dated through the airport table: a ferry
    /// out of Piraeus carries the chip "PIR", which is not an airport code at
    /// all, and a train out of Berlin Hbf carries "BER", which is — Brandenburg,
    /// possibly a continent away from the one the traveller is standing in.
    /// Either way the answer is a plausible date for the wrong place.
    static func apiDate(_ date: Date, in timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = timeZone
        return f.string(from: date)
    }

    /// Re-projects the wall-clock digits (year/month/day/hour/minute) of `date`,
    /// as read in the device's own calendar, onto `timeZone` — i.e. "16:22" stays
    /// "16:22" but becomes 16:22 in the target zone rather than 16:22 device-local.
    /// Used when a person enters a time that's meant to be local to some other
    /// place (e.g. a flight's departure airport) rather than local to themselves.
    static func reinterpretWallClock(_ date: Date, asLocalTo timeZone: TimeZone?) -> Date {
        guard let timeZone else { return date }
        let deviceComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        var targetCalendar = Calendar.current
        targetCalendar.timeZone = timeZone
        return targetCalendar.date(from: deviceComponents) ?? date
    }
}
