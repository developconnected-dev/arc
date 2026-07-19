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
}
