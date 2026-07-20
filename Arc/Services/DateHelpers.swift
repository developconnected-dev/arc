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
