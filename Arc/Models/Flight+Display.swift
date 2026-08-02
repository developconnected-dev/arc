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
        // Calendar days, not seconds/86400 — two flights on the same date
        // must show the same count regardless of departure hour.
        let cal = Calendar.current
        let days = cal.dateComponents(
            [.day], from: cal.startOfDay(for: .now), to: cal.startOfDay(for: scheduledDeparture)
        ).day ?? 0
        let hours = Int(interval) / 3600
        let minutes = Int(interval) / 60
        if days >= 1 && hours >= 12 { return ("\(days)", days == 1 ? "DAY" : "DAYS") }
        if hours >= 1 { return ("\(hours)", hours == 1 ? "HOUR" : "HOURS") }
        return ("\(max(1, minutes))", "MIN")
    }

    /// Near-term flight (within ~36h) → show live status instead of the date.
    var isSoon: Bool {
        let dt = scheduledDeparture.timeIntervalSince(.now)
        return dt > 0 && dt < 36 * 3600
    }

    var isDelayed: Bool { delayMinutes > 0 || status == .cancelled }

    /// True for 30 minutes after landing — kept visible in My Flights during
    /// this grace period (arrival gate, baggage claim) instead of moving
    /// straight to Passport the instant the status flips to landed.
    var isRecentlyLanded: Bool {
        guard status == .landed else { return false }
        let sinceLanding = Date.now.timeIntervalSince(actualArrival ?? scheduledArrival)
        return sinceLanding >= 0 && sinceLanding <= 30 * 60
    }

    /// Green when on-time/near, red when delayed/cancelled/diverted, gray when far-off.
    var accentColor: Color {
        if status == .cancelled || status == .diverted || delayMinutes > 15 { return ArcTheme.late }
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
        case .boarding: return "Boarding"
        case .gateClosed: return "Gate Closed"
        default: return delayMinutes > 0 ? "Delayed \(delayMinutes)m" : "On Time"
        }
    }

    /// Top-right label on a My Flights card.
    var cardTopRight: String {
        if isActive { return statusText }
        if isRecentlyLanded { return "Landed" }
        // Boarding/gate-closed read as standalone states, not "Departs Boarding".
        if isBoarding { return statusText }
        // Arc's own knock-on prediction — only shown while it says meaningfully
        // more than the airline's official number (showsPrediction gates that).
        if showsPrediction { return "Predicted +\(predictedDelayMinutes)m" }
        if isSoon { return "Departs \(statusText)" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE, d MMM"
        // Airport-local, like every time in the app: a 00:30 red-eye must
        // show its local departure DATE, not the date in the user's zone.
        f.timeZone = depTimeZone
        return f.string(from: scheduledDeparture)
    }

    var cardTopRightColor: Color {
        if status == .gateClosed { return ArcTheme.late }   // urgency — gate is closing/closed
        if showsPrediction { return .orange }               // predicted, not airline-confirmed
        return (isSoon || isActive || isRecentlyLanded || isBoarding) ? accentColor : Color(.secondaryLabel)
    }

    // MARK: - Detail screen helpers

    var departureAirportName: String { ReferenceData.shared.airport(departureIATA)?.name ?? departureCity }
    var arrivalAirportName: String { ReferenceData.shared.airport(arrivalIATA)?.name ?? arrivalCity }

    var headerDateText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE, d MMM"
        // Same rule as cardTopRight: the flight's date is its LOCAL date.
        f.timeZone = depTimeZone
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
        if mins <= -1 {
            let e = abs(mins), h = e / 60, m = e % 60
            return h > 0 ? "\(h)h \(m)m Early" : "\(m)m Early"
        }
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
    /// Whether either end of this flight runs on a different clock from the
    /// phone. When it does, times shown as airport-local can look wrong next to
    /// the device clock — an Athens departure at 13:39 reads as "in the future"
    /// on a Swiss phone showing 13:12, even though it has already left.
    var crossesDeviceTimezone: Bool {
        let device = TimeZone.current.secondsFromGMT(for: scheduledDeparture)
        return depTimeZone.secondsFromGMT(for: scheduledDeparture) != device
            || arrTimeZone.secondsFromGMT(for: scheduledArrival) != device
    }

    /// "Times shown in airport local time (ATH +1h)" — says which clock these
    /// numbers are on, and how far it is from the phone's, so the two
    /// disagreeing stops being confusing. Nil when there's nothing to explain.
    var timezoneNote: String? {
        guard crossesDeviceTimezone else { return nil }
        let device = TimeZone.current.secondsFromGMT(for: scheduledDeparture)
        let delta = (depTimeZone.secondsFromGMT(for: scheduledDeparture) - device) / 3600
        guard delta != 0 else { return "Times shown in each airport's local time" }
        let sign = delta > 0 ? "+" : "−"
        return "Times in each airport's local time · \(departureIATA) is \(sign)\(abs(delta))h from you"
    }

    var timezoneDeltaHours: Int {
        let dep = depTimeZone.secondsFromGMT(for: scheduledDeparture)
        let arr = arrTimeZone.secondsFromGMT(for: scheduledArrival)
        return (arr - dep) / 3600
    }

    var arrivalInDepartureLocal: String { hhmm(scheduledArrival, depTimeZone) }
}
