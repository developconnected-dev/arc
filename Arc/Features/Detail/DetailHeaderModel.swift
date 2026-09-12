import SwiftUI

/// Every word and tint the detail header shows, decided in one place so
/// the header itself is only layout. Three text sizes and one colour are
/// the rules; the model enforces the second: a time is tinted only when it
/// moved, and the only other colour on the header is the status pill.
struct DetailHeaderModel {
    struct Pill {
        let text: String
        let color: Color
    }

    struct Endpoint {
        let iata: String
        let city: String
        let name: String
        /// "HH:mm" in the airport's own zone — the effective time.
        let time: String
        /// The scheduled time, only when the effective one moved away from it.
        let scheduledIfMoved: String?
        let moved: Bool
        let tint: Color
        /// One line of context under the time: the countdown, or "your time".
        let context: String
        let terminal: String?
        let gate: String?
        /// A gate shown as "--" or as Arc's prediction rather than a fact.
        let gatePending: Bool
        let belt: String?
    }

    let number: String
    let date: String
    let pill: Pill
    let departure: Endpoint
    let arrival: Endpoint
    let duration: String

    init(flight f: Flight, now: Date = .now) {
        number = f.flightNumberSpaced
        date = f.headerDateText.capitalized
        pill = Pill(text: f.statusText, color: f.accentColor)
        duration = f.durationFormatted

        let cancelled = f.status == .cancelled || f.status == .diverted

        let depMoved = f.departureChanged
        departure = Endpoint(
            iata: f.departureIATA,
            city: f.departureCity.isEmpty ? f.departureAirportName : f.departureCity,
            name: f.departureAirportName,
            time: f.effectiveDepTimeLocal,
            scheduledIfMoved: depMoved ? f.depTimeLocal : nil,
            moved: depMoved,
            tint: cancelled ? ArcTheme.late : (depMoved ? Self.tint(effective: f.effectiveDeparture, scheduled: f.scheduledDeparture) : .primary),
            context: Self.departureContext(f),
            terminal: f.showsPredictedGate ? (f.departureTerminal ?? f.predictedDepartureTerminal) : f.departureTerminal,
            gate: f.departureGate ?? (f.showsPredictedGate ? f.predictedDepartureGate : nil),
            gatePending: f.departureGate == nil,
            belt: nil)

        let arrMoved = f.arrivalChanged
        arrival = Endpoint(
            iata: f.arrivalIATA,
            city: f.arrivalCity.isEmpty ? f.arrivalAirportName : f.arrivalCity,
            name: f.arrivalAirportName,
            time: f.effectiveArrTimeLocal,
            scheduledIfMoved: arrMoved ? f.arrTimeLocal : nil,
            moved: arrMoved,
            tint: cancelled ? ArcTheme.late : (f.showsArrivalPrediction ? .orange : (arrMoved ? Self.tint(effective: f.effectiveArrival, scheduled: f.scheduledArrival) : .primary)),
            context: Self.arrivalContext(f, now: now),
            terminal: f.arrivalTerminal,
            gate: f.arrivalGate,
            gatePending: f.arrivalGate == nil,
            belt: f.showsBaggageBelt ? f.baggageClaim : nil)
    }

    private static func tint(effective: Date, scheduled: Date) -> Color {
        effective.timeIntervalSince(scheduled) >= 60 ? ArcTheme.late : ArcTheme.onTime
    }

    /// "in 5h 28m" before departure; afterwards the relative text as it is
    /// ("Departed 12m ago", "Just departed", "3m past schedule").
    private static func departureContext(_ f: Flight) -> String {
        let rel = f.departureRelText
        let verb = "Departs "
        return rel.hasPrefix(verb) ? String(rel.dropFirst(verb.count)) : rel
    }

    /// The arrival on the phone's clock when that differs from the airport's
    /// — the one thing a traveller has to work out for themselves — else the
    /// arrival's own relative text.
    private static func arrivalContext(_ f: Flight, now: Date) -> String {
        let device = TimeZone.current
        let arrival = f.effectiveArrival
        if f.arrTimeZone.secondsFromGMT(for: arrival) != device.secondsFromGMT(for: arrival) {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_GB")
            fmt.timeZone = device
            fmt.dateFormat = "HH:mm"
            return "\(fmt.string(from: arrival)) your time"
        }
        return f.arrivalRelText
    }
}

/// The trip group below the header: what the traveller wrote down.
enum TripGroup {
    /// Nothing filled in — the three fields collapse into one "Add…" row.
    static func isEmpty(_ f: Flight) -> Bool {
        (f.bookingCode ?? "").isEmpty && (f.seat ?? "").isEmpty && f.notes.isEmpty
    }
}
