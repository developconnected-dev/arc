import Foundation

/// One absolute timeline for every until-gate / until-landing / relative
/// countdown. Wall clocks are a display concern (each airport's own zone);
/// remaining time is always `target − now` in seconds.
///
/// VY8462 BCN→LIS (CEST → WEST) jumped ~30m ↔ ~1h30m when a writer applied
/// the departure delay to the scheduled arrival — 20:00 LIS vs 21:00 LIS —
/// and when a formatter treated Lisbon HH:mm as the device's CEST digits.
enum FlightClock {
    /// Epoch remaining. Positive = still out. Display timezones are not an input.
    static func secondsUntil(_ target: Date, now: Date = .now) -> TimeInterval {
        target.timeIntervalSince(now)
    }

    /// Airport-local `HH:mm` for a stored instant. Never used to *build* a
    /// countdown target — only to print one.
    static func hhmm(_ date: Date, in timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = timeZone
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// A delay as a duration: "16m", "1h", "2h 25m". Under an hour it is
    /// minutes; from an hour it is hours, with the minutes only when there
    /// are any. "Delayed 200m" is a number nobody thinks in.
    static func delayText(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h >= 1 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(minutes)m"
    }

    /// "1h 38m" / "16m" style remaining; nil if the target is already past.
    static func compactUntil(_ date: Date, now: Date = .now) -> String? {
        let s = Int(secondsUntil(date, now: now))
        guard s > 0 else { return nil }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d >= 1 { return "\(d)d \(h)h" }
        if h >= 1 { return "\(h)h \(m)m" }
        return "\(max(1, m))m"
    }

    /// The arrival instant every surface counts down to.
    ///
    /// Actual wheels-down, then the provider/airline estimate, then
    /// scheduled arrival plus departure delay — never the delay when an
    /// estimate exists (the VY8462 30m / 90m flip), and never Arc's own
    /// remaining-time guess. That guess is a labeled prediction only
    /// when this stamp is missing.
    static func heroArrival(scheduled: Date, delayMinutes: Int,
                            estimated: Date? = nil, actual: Date? = nil) -> Date {
        if let actual { return actual }
        if let estimated { return estimated }
        if delayMinutes > 0 { return scheduled.addingTimeInterval(Double(delayMinutes) * 60) }
        return scheduled
    }
}
