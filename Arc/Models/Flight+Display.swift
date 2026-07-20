import Foundation
import SwiftUI

/// Presentation helpers used by the flight cards and detail screen.
extension Flight {
    var depTimeZone: TimeZone { ReferenceData.shared.timezone(departureIATA) ?? .current }
    var arrTimeZone: TimeZone { ReferenceData.shared.timezone(arrivalIATA) ?? .current }

    private func hhmm(_ date: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")   // 24h HH:mm
        f.timeZone = tz
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    var depTimeLocal: String { hhmm(scheduledDeparture, depTimeZone) }
    var arrTimeLocal: String { hhmm(scheduledArrival, arrTimeZone) }

    /// Airline IATA (first 2 chars of the flight number).
    var airlineCode: String { String(flightNumber.prefix(2)) }

    /// "LX1413" → "LX 1413".
    var flightNumberSpaced: String {
        let code = flightNumber.prefix(2)
        let rest = flightNumber.dropFirst(2)
        return rest.isEmpty ? String(code) : "\(code) \(rest)"
    }

    /// Countdown until departure — (value, unit) e.g. ("49","DAYS"), ("17","HOURS").
    var countdown: (value: String, unit: String)? {
        guard !isActive else { return nil }
        let interval = scheduledDeparture.timeIntervalSince(.now)
        guard interval > 0 else { return nil }
        let days = Int(interval) / 86400
        let hours = Int(interval) / 3600
        let minutes = Int(interval) / 60
        if days >= 1 { return ("\(days)", days == 1 ? "DAY" : "DAYS") }
        if hours >= 1 { return ("\(hours)", hours == 1 ? "HOUR" : "HOURS") }
        return ("\(max(1, minutes))", "MIN")
    }

    /// Near-term flight (within ~36h) → show live status instead of the date.
    var isSoon: Bool {
        let dt = scheduledDeparture.timeIntervalSince(.now)
        return dt > 0 && dt < 36 * 3600
    }

    var isDelayed: Bool { delayMinutes > 0 || status == .cancelled }

    /// Green when on-time/near, red when delayed/cancelled, gray when far-off.
    var accentColor: Color {
        if status == .cancelled || delayMinutes > 15 { return ArcTheme.late }
        if delayMinutes > 0 { return ArcTheme.late }
        if isSoon || isActive || status == .landed { return ArcTheme.onTime }
        return Color(.secondaryLabel)
    }

    var statusText: String {
        switch status {
        case .cancelled: return "Cancelled"
        case .landed: return "Landed"
        case .active: return delayMinutes > 0 ? "In Air • \(delayMinutes)m late" : "In Air"
        case .diverted: return "Diverted"
        default: return delayMinutes > 0 ? "Delayed \(delayMinutes)m" : "On Time"
        }
    }

    /// Top-right label on a My Flights card.
    var cardTopRight: String {
        if isActive { return statusText }
        if isSoon { return "Departs \(statusText)" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE, d MMM"
        return f.string(from: scheduledDeparture)
    }

    var cardTopRightColor: Color {
        (isSoon || isActive) ? accentColor : Color(.secondaryLabel)
    }

    // MARK: - Detail screen helpers

    var departureAirportName: String { ReferenceData.shared.airport(departureIATA)?.name ?? departureCity }
    var arrivalAirportName: String { ReferenceData.shared.airport(arrivalIATA)?.name ?? arrivalCity }

    var headerDateText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE, d MMM"
        return f.string(from: scheduledDeparture).uppercased()
    }

    /// The effective (live) departure/arrival time. Prefers an explicit actual/estimated
    /// timestamp; when the API only gave us a delay count (the common case), derives the
    /// effective time from `scheduledDeparture/Arrival + delayMinutes` so the delay actually
    /// shows up as a late/colored time instead of silently reading as "On Time" everywhere.
    var effectiveDeparture: Date {
        if let actualDeparture { return actualDeparture }
        if delayMinutes > 0 { return scheduledDeparture.addingTimeInterval(Double(delayMinutes) * 60) }
        return scheduledDeparture
    }
    var effectiveArrival: Date {
        if let estimatedArrival { return estimatedArrival }
        if let actualArrival { return actualArrival }
        if delayMinutes > 0 { return scheduledArrival.addingTimeInterval(Double(delayMinutes) * 60) }
        return scheduledArrival
    }

    var departureChanged: Bool { abs(effectiveDeparture.timeIntervalSince(scheduledDeparture)) >= 60 }
    var arrivalChanged: Bool { abs(effectiveArrival.timeIntervalSince(scheduledArrival)) >= 60 }

    var effectiveDepTimeLocal: String { hhmm(effectiveDeparture, depTimeZone) }
    var effectiveArrTimeLocal: String { hhmm(effectiveArrival, arrTimeZone) }

    /// "1h 38m" style countdown to a date; nil if past.
    private func compactUntil(_ date: Date) -> String? {
        let s = Int(date.timeIntervalSince(.now))
        guard s > 0 else { return nil }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d >= 1 { return "\(d)d \(h)h" }
        if h >= 1 { return "\(h)h \(m)m" }
        return "\(max(1, m))m"
    }

    /// Banner headline: "Gate Departure in 1h 38m", "Landing in 6h 43m", etc.
    var bannerHeadline: String {
        switch status {
        case .cancelled: return "Flight Cancelled"
        case .landed: return "Landed"
        case .active:
            if let t = compactUntil(effectiveArrival) { return "Landing in \(t)" }
            return "Arriving"
        default:
            if let t = compactUntil(effectiveDeparture) { return "Gate Departure in \(t)" }
            return "Departing"
        }
    }

    var bannerColor: Color {
        if status == .cancelled { return ArcTheme.late }
        if isDelayed { return ArcTheme.late }
        return ArcTheme.onTime
    }

    /// "On Time", "1h 2m Late", etc. for an endpoint given its delta.
    private func deltaLabel(effective: Date, scheduled: Date) -> String {
        let mins = Int(effective.timeIntervalSince(scheduled) / 60)
        if mins <= -1 { return "\(abs(mins))m Early" }
        if mins >= 1 {
            let h = mins / 60, m = mins % 60
            return h > 0 ? "\(h)h \(m)m Late" : "\(m)m Late"
        }
        return "On Time"
    }
    var departureStatusText: String { deltaLabel(effective: effectiveDeparture, scheduled: scheduledDeparture) }
    var arrivalStatusText: String { deltaLabel(effective: effectiveArrival, scheduled: scheduledArrival) }

    var departureRelText: String {
        if let t = compactUntil(effectiveDeparture) { return "Departs in \(t)" }
        return "\(compactAgo(effectiveDeparture)) ago"
    }

    /// "5m", "2h 10m", or "61d" style elapsed time — mirrors `compactUntil`'s
    /// day-bucketing so a flight from months ago doesn't read as "1463h 34m ago".
    private func compactAgo(_ date: Date) -> String {
        let s = max(0, Int(-date.timeIntervalSince(.now)))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d >= 1 { return "\(d)d \(h)h" }
        if h >= 1 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
    var arrivalRelText: String {
        if let t = compactUntil(effectiveArrival) { return "Arrives in \(t)" }
        return "Arrived"
    }

    /// Timezone offset difference dep→arr in whole hours.
    var timezoneDeltaHours: Int {
        let dep = depTimeZone.secondsFromGMT(for: scheduledDeparture)
        let arr = arrTimeZone.secondsFromGMT(for: scheduledArrival)
        return (arr - dep) / 3600
    }

    var arrivalInDepartureLocal: String { hhmm(scheduledArrival, depTimeZone) }
}
