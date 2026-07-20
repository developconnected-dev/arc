import Foundation

enum DateHelpers {
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
