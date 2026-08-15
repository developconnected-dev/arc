import Foundation

/// Shared data model between the main app and widget extension.
/// Uses App Group UserDefaults since SwiftData can't easily share across targets.
enum WidgetData {
    static let appGroupID = "group.com.arc.flighttracker"

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    // MARK: - Write (from main app)

    static func save(flights: [WidgetFlight]) {
        guard let data = try? JSONEncoder().encode(flights) else { return }
        sharedDefaults?.set(data, forKey: "widget_flights")
    }

    // MARK: - Read (from widget)

    static func loadFlights() -> [WidgetFlight] {
        guard let data = sharedDefaults?.data(forKey: "widget_flights"),
              let flights = try? JSONDecoder().decode([WidgetFlight].self, from: data)
        else { return [] }
        return flights
    }
}

/// Lightweight Codable flight for widget display.
struct WidgetFlight: Identifiable {
    let id: String
    let flightNumber: String
    let airline: String
    let departureIATA: String
    let arrivalIATA: String
    let departureCity: String
    let arrivalCity: String
    let scheduledDeparture: Date
    let scheduledArrival: Date
    let status: String
    let delayMinutes: Int
    let departureGate: String?
    let progress: Double
    /// Arc's own knock-on prediction. 0 when the airline's delay already
    /// covers it (or there isn't one). The home widget uses this to say
    /// "Arc +32m" instead of a green On Time the inbound will miss.
    var predictedDelayMinutes: Int = 0

    /// How this leg travels. Defaulted to air so every snapshot written before
    /// trip modes existed keeps meaning what it meant.
    var mode: TripMode = .air

    /// How much the source actually knows — see `DataTier`. A published
    /// timetable is not a claim that anything is on time, and this is what
    /// stops the widget making that claim on its behalf.
    var dataTier: DataTier = .live

    // The facts a traveller actually glances at the home screen for — all
    // optional so snapshots written before they existed still decode.
    var departureTerminal: String? = nil
    var arrivalGate: String? = nil
    var arrivalTerminal: String? = nil
    var baggageClaim: String? = nil
    /// Provider-revised arrival, when there is one; the countdown targets it.
    var estimatedArrival: Date? = nil
    /// IANA zone identifiers, so the widget can print each end's LOCAL time the
    /// way every other surface does. nil → device zone (older snapshots).
    var departureTZ: String? = nil
    var arrivalTZ: String? = nil
    /// When these facts were last confirmed against a source. Drives the
    /// "as of" honesty line and the widget's own refresh decisions.
    var updatedAt: Date? = nil

    /// Status-only, no clock comparison — mirrors Flight.isUpcoming. The old
    /// `&& scheduledDeparture > .now` had the same dead zone the app model
    /// did: any delayed flight past its original scheduled time (but not yet
    /// confirmed departed) vanished from the widget exactly when the user
    /// most wants to see it.
    var isUpcoming: Bool {
        status == "scheduled" || status == "boarding" || status == "gateClosed"
    }

    var isActive: Bool {
        status == "active"
    }

    /// Same bar as `Flight.showsPrediction`: only when Arc knows ~10m more
    /// than the airline has admitted.
    var showsPrediction: Bool {
        (status == "scheduled" || status == "boarding") && predictedDelayMinutes >= delayMinutes + 10
    }

    /// The trip is off. `phase(at:)` sends these to `.landed` (there is no
    /// arrival to count down to), so every label and colour has to check this
    /// FIRST or a cancelled flight reads as "Arriving soon" in green.
    var isDisrupted: Bool {
        status == "cancelled" || status == "diverted"
    }

    /// May this leg wear a status colour and a delay figure at all? Same rule as
    /// `Flight.reportsPunctuality`, deliberately duplicated rather than derived,
    /// because the widget must not be able to drift from the app: only a source
    /// that reports revised times has an opinion on punctuality — and a
    /// cancellation is a reported fact in any mode.
    var reportsPunctuality: Bool {
        dataTier.reportsPunctuality || status == "cancelled"
    }

    /// Big-slot label once a countdown no longer applies.
    var terminalLabel: String {
        if status == "cancelled" { return "Cancelled" }
        if status == "diverted" { return "Diverted" }
        return status == "landed" ? mode.arrivedVerb : "Arriving"
    }

    func statusText(phase: Phase) -> String {
        if status == "cancelled" { return "Cancelled" }
        if status == "diverted" { return "Diverted" }
        switch phase {
        case .inFlight: return mode.inTransitTitle
        case .landed: return status == "landed" ? mode.arrivedVerb : "\(mode.arrivingVerb) soon"
        case .upcoming:
            if showsPrediction { return "Arc +\(predictedDelayMinutes)m" }
            // "On Time" is a quote, not a guess. With only a timetable to go on
            // there is nobody to quote, so name the source instead — a green
            // On Time on a ferry was Arc inventing a fact.
            guard reportsPunctuality else { return dataTier.qualifier ?? "Scheduled" }
            if delayMinutes > 0 { return "Delayed \(delayMinutes)m" }
            return "On Time"
        }
    }

    /// Departure adjusted by the known delay — what countdowns should target.
    var effectiveDeparture: Date {
        scheduledDeparture.addingTimeInterval(Double(max(0, delayMinutes)) * 60)
    }

    var effectiveArrival: Date {
        // The provider's own revised arrival beats "schedule + departure delay"
        // — a late departure that makes time up in the air is the common case.
        estimatedArrival ?? scheduledArrival.addingTimeInterval(Double(max(0, delayMinutes)) * 60)
    }

    /// Wall-clock at each end, in that place's own zone — the same rule every
    /// other Arc surface follows. Falls back to the device zone for snapshots
    /// written before zones were carried.
    func localTime(_ date: Date, zone id: String?) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = id.flatMap(TimeZone.init(identifier:)) ?? .current
        return f.string(from: date)
    }
    var depTimeLocal: String { localTime(effectiveDeparture, zone: departureTZ) }
    var arrTimeLocal: String { localTime(effectiveArrival, zone: arrivalTZ) }

    enum Phase { case upcoming, inFlight, landed }

    /// Phase as of a given moment — CLOCK-based, not status-string-based.
    /// The stored status only changes when the app runs; widget timeline
    /// entries render at future dates while the app may be closed and the
    /// device offline. Deriving the phase from the entry's own date is what
    /// makes the pre-flight → in-flight → landed layout switch happen
    /// automatically without the user ever opening the app. A trusted status
    /// (active/landed from the API) still wins when it's ahead of the clock.
    func phase(at date: Date) -> Phase {
        if status == "landed" || status == "cancelled" || status == "diverted" { return .landed }
        if status == "active" { return date >= effectiveArrival ? .landed : .inFlight }
        if date >= effectiveArrival { return .landed }
        if date >= effectiveDeparture { return .inFlight }
        return .upcoming
    }

    var timeUntilDeparture: TimeInterval {
        scheduledDeparture.timeIntervalSince(.now)
    }

    var countdownText: String {
        let interval = timeUntilDeparture
        if interval <= 0 { return "Now" }
        let hours = Int(interval) / 3600
        let mins = (Int(interval) % 3600) / 60
        if hours > 24 {
            let days = hours / 24
            return "\(days)d \(hours % 24)h"
        }
        if hours > 0 {
            return "\(hours)h \(mins)m"
        }
        return "\(mins)m"
    }

}

/// Custom decode so App Group snapshots written before `predictedDelayMinutes`,
/// `mode` or `dataTier` existed still load (synthesized Codable would fail the
/// whole widget, which renders as an empty widget the user can't fix).
extension WidgetFlight: Codable {
    enum CodingKeys: String, CodingKey {
        case id, flightNumber, airline, departureIATA, arrivalIATA
        case departureCity, arrivalCity, scheduledDeparture, scheduledArrival
        case status, delayMinutes, departureGate, progress, predictedDelayMinutes
        case mode, dataTier
        case departureTerminal, arrivalGate, arrivalTerminal, baggageClaim
        case estimatedArrival, departureTZ, arrivalTZ, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        flightNumber = try c.decode(String.self, forKey: .flightNumber)
        airline = try c.decode(String.self, forKey: .airline)
        departureIATA = try c.decode(String.self, forKey: .departureIATA)
        arrivalIATA = try c.decode(String.self, forKey: .arrivalIATA)
        departureCity = try c.decode(String.self, forKey: .departureCity)
        arrivalCity = try c.decode(String.self, forKey: .arrivalCity)
        scheduledDeparture = try c.decode(Date.self, forKey: .scheduledDeparture)
        scheduledArrival = try c.decode(Date.self, forKey: .scheduledArrival)
        status = try c.decode(String.self, forKey: .status)
        delayMinutes = try c.decode(Int.self, forKey: .delayMinutes)
        departureGate = try c.decodeIfPresent(String.self, forKey: .departureGate)
        progress = try c.decode(Double.self, forKey: .progress)
        predictedDelayMinutes = try c.decodeIfPresent(Int.self, forKey: .predictedDelayMinutes) ?? 0
        mode = try c.decodeIfPresent(TripMode.self, forKey: .mode) ?? .air
        dataTier = try c.decodeIfPresent(DataTier.self, forKey: .dataTier) ?? .live
        departureTerminal = try c.decodeIfPresent(String.self, forKey: .departureTerminal)
        arrivalGate = try c.decodeIfPresent(String.self, forKey: .arrivalGate)
        arrivalTerminal = try c.decodeIfPresent(String.self, forKey: .arrivalTerminal)
        baggageClaim = try c.decodeIfPresent(String.self, forKey: .baggageClaim)
        estimatedArrival = try c.decodeIfPresent(Date.self, forKey: .estimatedArrival)
        departureTZ = try c.decodeIfPresent(String.self, forKey: .departureTZ)
        arrivalTZ = try c.decodeIfPresent(String.self, forKey: .arrivalTZ)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(flightNumber, forKey: .flightNumber)
        try c.encode(airline, forKey: .airline)
        try c.encode(departureIATA, forKey: .departureIATA)
        try c.encode(arrivalIATA, forKey: .arrivalIATA)
        try c.encode(departureCity, forKey: .departureCity)
        try c.encode(arrivalCity, forKey: .arrivalCity)
        try c.encode(scheduledDeparture, forKey: .scheduledDeparture)
        try c.encode(scheduledArrival, forKey: .scheduledArrival)
        try c.encode(status, forKey: .status)
        try c.encode(delayMinutes, forKey: .delayMinutes)
        try c.encodeIfPresent(departureGate, forKey: .departureGate)
        try c.encode(progress, forKey: .progress)
        try c.encode(predictedDelayMinutes, forKey: .predictedDelayMinutes)
        try c.encode(mode, forKey: .mode)
        try c.encode(dataTier, forKey: .dataTier)
        try c.encodeIfPresent(departureTerminal, forKey: .departureTerminal)
        try c.encodeIfPresent(arrivalGate, forKey: .arrivalGate)
        try c.encodeIfPresent(arrivalTerminal, forKey: .arrivalTerminal)
        try c.encodeIfPresent(baggageClaim, forKey: .baggageClaim)
        try c.encodeIfPresent(estimatedArrival, forKey: .estimatedArrival)
        try c.encodeIfPresent(departureTZ, forKey: .departureTZ)
        try c.encodeIfPresent(arrivalTZ, forKey: .arrivalTZ)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }
}
