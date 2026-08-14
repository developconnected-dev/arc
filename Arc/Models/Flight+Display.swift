import Foundation
import SwiftUI

/// Presentation helpers used by the flight cards and detail screen.
extension Flight {
    /// The leg's own stored zone wins over the airport table.
    ///
    /// `ReferenceData.timezone` resolves an IATA code against the bundled
    /// airport database, which is the right answer for a flight and a trap for
    /// anything else: a station or port code is not an airport code, and some
    /// derived codes collide with real ones — a ferry leg from Piraeus stamped
    /// "PIR" would happily inherit a timezone from an airport on another
    /// continent and be wrong without ever looking wrong. Rail and sea legs
    /// therefore carry a zone of their own, resolved server-side.
    private func zone(_ stored: String?, _ code: String) -> TimeZone {
        if let stored, let z = TimeZone(identifier: stored) { return z }
        if mode == .air, let z = ReferenceData.shared.timezone(code) { return z }
        return .current
    }

    var depTimeZone: TimeZone { zone(departureTZID, departureIATA) }
    var arrTimeZone: TimeZone { zone(arrivalTZID, arrivalIATA) }

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
    ///
    /// Air only. "ICE 373" would yield "IC" and "BLUE STAR DELOS" would yield
    /// "BL" — both plausible-looking airline codes that would pull an unrelated
    /// carrier's logo onto a train or a ferry.
    var airlineCode: String { mode == .air ? String(flightNumber.prefix(2)) : "" }

    /// "LX1413" → "LX 1413".
    var flightNumberSpaced: String {
        // Only flight numbers are code-then-digits; a service name is already
        // spaced the way its operator writes it.
        mode == .air ? Self.spaced(flightNumber) : flightNumber
    }

    /// What to call the gate/platform/berth for this leg.
    var boardingPointLabel: String { mode.boardingPointLabel }

    static func spaced(_ number: String) -> String {
        let code = number.prefix(2)
        let rest = number.dropFirst(2)
        return rest.isEmpty ? String(code) : "\(code) \(rest)"
    }

    /// The number on the ticket, when it isn't the number that flies.
    ///
    /// A codeshare is booked as one flight and operated as another: the ticket
    /// says A3 1653, the aircraft is Lufthansa's LH 1751. Only the operating
    /// number can be tracked, so that's what's stored — but showing it alone
    /// means the flight in the list doesn't match the booking confirmation the
    /// person is holding, which is exactly the moment they think the app got
    /// it wrong.
    ///
    /// nil whenever there's nothing extra to say — an ordinary flight, or a
    /// codeshare whose marketing number happens to match the operator's.
    var marketingLabel: String? {
        guard let marketing = marketingFlightNumber?.trimmingCharacters(in: .whitespaces),
              !marketing.isEmpty,
              marketing.uppercased() != flightNumber.uppercased() else { return nil }
        let iata = String(marketing.prefix(2))
        let name = ReferenceData.shared.airline(iata)?.name
        return [name, Self.spaced(marketing)].compactMap { $0 }.joined(separator: " ")
    }

    /// "LH 1751 · Aegean Airlines A3 1653", or just "LH 1751".
    var flightNumberWithMarketing: String {
        marketingLabel.map { "\(flightNumberSpaced)  ·  \($0)" } ?? flightNumberSpaced
    }

    /// The same thing without the airline's name — for places too narrow for
    /// the full form, where "LH 1751 · A3 1653" still says the useful part.
    var flightNumberWithMarketingShort: String {
        guard let marketing = marketingFlightNumber, marketingLabel != nil else { return flightNumberSpaced }
        return "\(flightNumberSpaced)  ·  \(Self.spaced(marketing))"
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

    var isDelayed: Bool { (reportsPunctuality && delayMinutes > 0) || status == .cancelled }

    /// True for 30 minutes after landing — kept visible in My Flights during
    /// this grace period (arrival gate, baggage claim) instead of moving
    /// straight to Passport the instant the status flips to landed.
    var isRecentlyLanded: Bool {
        guard status == .landed else { return false }
        let sinceLanding = Date.now.timeIntervalSince(actualArrival ?? scheduledArrival)
        return sinceLanding >= 0 && sinceLanding <= 30 * 60
    }

    /// Lock-screen smart line when the Worker hasn't pushed one. Mirrors the
    /// in-app prediction, clipped to the Live Activity's ~70 character budget.
    var liveActivityInsight: String? {
        guard showsPrediction else { return nil }
        let head = "Arc predicts +\(predictedDelayMinutes)m"
        guard let reason = predictionReason, !reason.isEmpty else { return head }
        let room = 70 - head.count - 3
        guard room > 8 else { return head }
        if reason.count <= room { return "\(head) — \(reason)" }
        return "\(head) — \(reason.prefix(room - 1))…"
    }

    /// Has the operator actually told us this leg is running to time?
    ///
    /// Only a `.live` source ever says so. A ferry timetable is a plan, not a
    /// report, and no Mediterranean operator publishes a per-sailing revised
    /// time — so painting a sailing green would be Arc asserting something
    /// nobody told it. Cancellation stays loud in every tier, because a
    /// disruption notice IS a report.
    var reportsPunctuality: Bool {
        dataTier.reportsPunctuality || status == .cancelled
    }

    /// Green when on-time/near, red when delayed/cancelled/diverted, gray when far-off.
    var accentColor: Color {
        if status == .cancelled || status == .diverted { return ArcTheme.late }
        guard reportsPunctuality else {
            // A timetable-only leg is never green. The operator's own notice is
            // the one thing worth colouring, and it's a warning, not a delay.
            return disruptionNote != nil ? .orange : Color(.secondaryLabel)
        }
        if delayMinutes > 15 { return ArcTheme.late }
        if delayMinutes > 0 { return ArcTheme.late }
        if isSoon || isActive || status == .landed { return ArcTheme.onTime }
        return Color(.secondaryLabel)
    }

    var statusText: String {
        switch status {
        case .cancelled: return "Cancelled"
        case .landed: return mode == .air ? "Landed" : "Arrived"
        case .active:
            let moving = mode.inTransitTitle
            guard reportsPunctuality, delayMinutes > 0 else { return moving }
            return "\(moving) • \(delayMinutes)m late"
        case .diverted: return "Diverted"
        case .boarding: return "Boarding"
        case .gateClosed: return mode == .air ? "Gate Closed" : "Departing"
        default:
            // Nothing published a revised time, so say where the time came from
            // rather than claiming it is being kept to.
            guard reportsPunctuality else {
                if disruptionNote != nil { return "Check Operator Notice" }
                return dataTier.qualifier ?? "Scheduled"
            }
            return delayMinutes > 0 ? "Delayed \(delayMinutes)m" : "On Time"
        }
    }

    /// Top-right label on a My Flights card.
    var cardTopRight: String {
        if isActive { return statusText }
        if isRecentlyLanded { return mode.arrivedVerb }
        // Boarding/gate-closed read as standalone states, not "Departs Boarding".
        if isBoarding { return statusText }
        // Arc's own knock-on prediction — only shown while it says meaningfully
        // more than the airline's official number (showsPrediction gates that).
        if showsPrediction { return "Predicted +\(predictedDelayMinutes)m" }
        // "Departs On Time" reads; "Departs Timetable" does not. Where the
        // status names the SOURCE rather than a punctuality, it stands alone.
        if isSoon { return reportsPunctuality ? "Departs \(statusText)" : statusText }
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

    /// The full name of each endpoint.
    ///
    /// Air only for the table lookup, and this is the sharpest example of why:
    /// the port code for Piraeus is PIR, which is also Pierre Regional Airport
    /// in South Dakota — so a Greek sailing announced itself as departing from
    /// Pierre. Codes collide across the three networks constantly, and a wrong
    /// name that looks authoritative is worse than a plain one.
    var departureAirportName: String {
        (mode == .air ? ReferenceData.shared.airport(departureIATA)?.name : nil) ?? departureCity
    }
    var arrivalAirportName: String {
        (mode == .air ? ReferenceData.shared.airport(arrivalIATA)?.name : nil) ?? arrivalCity
    }

    /// Is there a real distance to show? Ferry ports carry no coordinates from
    /// the provider, and "0 km" is a false statement rather than a missing one.
    var hasRoute: Bool {
        !(departureLat == 0 && departureLon == 0) && !(arrivalLat == 0 && arrivalLon == 0)
    }

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
        case .cancelled: return mode == .air ? "Flight Cancelled" : "Cancelled"
        case .landed: return mode.arrivedVerb
        case .active:
            if let t = compactUntil(effectiveArrival) { return "\(mode.arrivingVerb) in \(t)" }
            return "Arriving"
        default:
            // "Gate Departure" names a gate a ferry doesn't have; a berth is not
            // where a sailing's clock starts either.
            let what = mode == .air ? "Gate Departure" : "Departure"
            if let t = compactUntil(effectiveDeparture) { return "\(what) in \(t)" }
            return "Departing"
        }
    }

    var bannerColor: Color {
        if status == .cancelled { return ArcTheme.late }
        if isDelayed { return ArcTheme.late }
        // Green is the app saying "this is running to plan". A timetable has no
        // opinion on that, so a sailing gets the neutral treatment rather than
        // a reassurance nobody issued.
        guard reportsPunctuality else { return disruptionNote != nil ? .orange : Color(.secondaryLabel) }
        return ArcTheme.onTime
    }

    /// "On Time", "1h 2m Late", etc. for an endpoint given its delta.
    private func deltaLabel(effective: Date, scheduled: Date) -> String {
        // Without a revised time there is no delta to describe, and "On Time"
        // would be a claim about punctuality the source never made. Name where
        // the time came from instead.
        guard reportsPunctuality else { return dataTier.qualifier ?? "Scheduled" }
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
        // "airport" is wrong for two of the three modes.
        let place = mode == .air ? "airport" : (mode == .rail ? "station" : "port")
        guard delta != 0 else { return "Times shown in each \(place)'s local time" }
        let sign = delta > 0 ? "+" : "−"
        return "Times in each \(place)'s local time · \(departureIATA) is \(sign)\(abs(delta))h from you"
    }

    var timezoneDeltaHours: Int {
        let dep = depTimeZone.secondsFromGMT(for: scheduledDeparture)
        let arr = arrTimeZone.secondsFromGMT(for: scheduledArrival)
        return (arr - dep) / 3600
    }

    var arrivalInDepartureLocal: String { hhmm(scheduledArrival, depTimeZone) }
}
