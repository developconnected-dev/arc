import Foundation

/// Shared data model between the main app and widget extension.
/// Uses App Group UserDefaults since SwiftData can't easily share across targets.
enum WidgetData {
    static let appGroupID = "group.com.arc.flighttracker"

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    // MARK: - Write (from main app)

    /// Write the snapshot. Returns whether anything actually changed, so the
    /// caller can spend a WidgetKit reload only when there is news. Reloads
    /// are a scarce daily budget: burning them on identical snapshots (the
    /// app rewrites this every 60 s while it is open, when the home screen is
    /// not even on screen) leaves none for later, when the app is closed and
    /// the widget is the only surface the traveller has.
    @discardableResult
    static func save(flights: [WidgetFlight]) -> Bool {
        guard let data = try? JSONEncoder().encode(flights) else { return false }
        if sharedDefaults?.data(forKey: "widget_flights") == data { return false }
        sharedDefaults?.set(data, forKey: "widget_flights")
        return true
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
    // `var` because `mergingForward` reconciles the two writers of this
    // snapshot in place; everything above is leg identity and never moves.
    var status: String
    let delayMinutes: Int
    var departureGate: String?
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
    /// A take-off some source actually reported — the one thing that lets
    /// the widget state the leg is flying rather than hedge about it.
    var actualDeparture: Date? = nil
    // What Arc knows about the gate-to-runway gap, carried so the home
    // screen can reason about it with the app dead and the device offline
    // (see DepartureEvidence). All optional: older snapshots decode as nil,
    // which simply means "no evidence, fall back to the clock".
    var estimatedTakeoff: Date? = nil
    var groundState: String? = nil
    var groundObservedAt: Date? = nil
    var taxiStartedAt: Date? = nil
    var lastSeenOnGround: Date? = nil
    var taxiPriorMinutes: Int? = nil

    /// Fold this leg over the snapshot the App Group already holds.
    ///
    /// Two writers share that snapshot: the app (from SwiftData) and the
    /// widget's own timeline refresh (from the Worker). They learn different
    /// things at different moments, and a plain overwrite means whichever
    /// wrote last silently un-knows the other's facts — the home screen
    /// re-hedging a take-off it had already confirmed, because the app synced
    /// a model that had not caught up yet. Evidence therefore only ever
    /// accumulates: a confirmed departure is never dropped, and a sighting is
    /// never wound back to an older one.
    func mergingForward(over previous: WidgetFlight?) -> WidgetFlight {
        guard let previous, previous.id == id else { return self }
        var out = self
        if Self.statusRegresses(status, from: previous.status) { out.status = previous.status }
        out.actualDeparture = actualDeparture ?? previous.actualDeparture
        out.estimatedTakeoff = estimatedTakeoff ?? previous.estimatedTakeoff
        out.taxiStartedAt = taxiStartedAt ?? previous.taxiStartedAt
        out.taxiPriorMinutes = taxiPriorMinutes ?? previous.taxiPriorMinutes
        // The most recent sighting wins, and it carries its own verdict:
        // pairing a new timestamp with an old state would describe a moment
        // that never happened.
        if (previous.groundObservedAt ?? .distantPast) > (groundObservedAt ?? .distantPast) {
            out.groundObservedAt = previous.groundObservedAt
            out.groundState = previous.groundState
        }
        out.lastSeenOnGround = Self.later(lastSeenOnGround, previous.lastSeenOnGround)
        out.updatedAt = Self.later(updatedAt, previous.updatedAt)
        // A provider null must not erase a fact either writer already had.
        out.departureGate = departureGate ?? previous.departureGate
        out.departureTerminal = departureTerminal ?? previous.departureTerminal
        out.arrivalGate = arrivalGate ?? previous.arrivalGate
        out.arrivalTerminal = arrivalTerminal ?? previous.arrivalTerminal
        out.baggageClaim = baggageClaim ?? previous.baggageClaim
        out.estimatedArrival = estimatedArrival ?? previous.estimatedArrival
        return out
    }

    /// Status only ever moves forward, except into cancelled or diverted,
    /// which are facts that outrank progress.
    ///
    /// Shared by both places a fresher-looking write can arrive carrying a
    /// staler status: the App Group merge below, and the Live Activity pushes
    /// the app absorbs. Without it, a provider still saying "scheduled" would
    /// un-fly a flight some source had already watched leave the ground.
    static func statusRegresses(_ incoming: String, from current: String) -> Bool {
        if incoming == "cancelled" || incoming == "diverted" { return false }
        let rank = ["scheduled": 0, "boarding": 1, "gateClosed": 2, "active": 3, "landed": 4]
        guard let new = rank[incoming], let old = rank[current] else { return false }
        return new < old
    }

    private static func later(_ a: Date?, _ b: Date?) -> Date? {
        guard let a else { return b }
        guard let b else { return a }
        return max(a, b)
    }

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

    /// Worth leading with. An "active" leg whose arrival is long past — the
    /// status never flipped because the app wasn't opened — must not hijack
    /// the widget for days, nor block the refresh of the real next trip.
    func isCurrent(at now: Date) -> Bool {
        if isUpcoming { return true }
        if isActive { return effectiveArrival.timeIntervalSince(now) > -45 * 60 }
        return false
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

    /// Gate departure — the schedule plus the airline's own delay. The taxi
    /// is measured from here, not from `effectiveDeparture` (which prefers a
    /// confirmed take-off, the wrong anchor for this question).
    var offBlock: Date {
        scheduledDeparture.addingTimeInterval(Double(max(0, delayMinutes)) * 60)
    }

    /// Everything the home screen knows about whether this leg has left the
    /// ground. Same type the app and the friends feed consult, so the widget
    /// cannot drift from them.
    var departureEvidence: DepartureEvidence {
        DepartureEvidence(
            mode: mode,
            offBlock: offBlock,
            estimatedTakeoff: estimatedTakeoff,
            actualDeparture: actualDeparture,
            groundState: groundState,
            groundObservedAt: groundObservedAt,
            taxiStartedAt: taxiStartedAt,
            lastSeenOnGround: lastSeenOnGround,
            taxiPriorMinutes: taxiPriorMinutes)
    }

    /// Takes the moment explicitly because widget entries render at future
    /// dates, never at Date.now.
    func departurePhase(at date: Date) -> DeparturePhase {
        if status == "landed" || status == "diverted" { return .airborne }
        if status == "cancelled" { return .beforeDeparture }
        let phase = departureEvidence.phase(at: date)
        if status == "active", phase == .beforeDeparture { return .airborne }
        return phase
    }

    /// Believed still on the ground: taxiing, or not yet expected to be off
    /// it. The widget hedges here — "Departing"/"Taxiing", never green.
    func isDepartingUnconfirmed(at date: Date) -> Bool {
        guard actualDeparture == nil, phase(at: date) == .inFlight else { return false }
        return !departurePhase(at: date).isOffTheGround
    }

    /// When the wheels are expected to leave the ground — the moment the
    /// timeline has to schedule an entry for, because it is the only moment
    /// the label may change without any new data arriving.
    var expectedWheelsUp: Date { departureEvidence.expectedWheelsUp }

    /// Every moment this leg's layout can change on its own.
    ///
    /// Widget entries are rendered once, at timeline-build time, so anything
    /// the view derives from the entry's date has to have an entry at the
    /// moment it changes — otherwise the home screen keeps showing the last
    /// render, with the app dead and the device offline, which is exactly
    /// the situation this whole hedge exists for. Three moments: the gate
    /// time, the expected wheels-up (while nobody has confirmed one), and
    /// the arrival.
    func layoutFlips(after now: Date) -> [Date] {
        var flips = [effectiveDeparture, effectiveArrival]
        if actualDeparture == nil { flips.append(expectedWheelsUp) }
        return flips.filter { $0 > now }.sorted()
    }

    func statusText(phase: Phase, at date: Date = .now) -> String {
        if status == "cancelled" { return "Cancelled" }
        if status == "diverted" { return "Diverted" }
        switch phase {
        case .inFlight:
            switch departurePhase(at: date) {
            case .taxiing: return mode == .air ? "Taxiing" : "Departing"
            case .departing: return "Departing"
            case .beforeDeparture, .presumedAirborne, .airborne: return mode.inTransitTitle
            }
        case .landed: return status == "landed" ? mode.arrivedVerb : "\(mode.arrivingVerb) soon"
        case .upcoming:
            if showsPrediction { return "Arc +\(predictedDelayMinutes)m" }
            // "On Time" is a quote, not a guess. With only a timetable to go on
            // there is nobody to quote, so name the source instead — a green
            // On Time on a ferry was Arc inventing a fact.
            guard reportsPunctuality else { return dataTier.qualifier ?? "Scheduled" }
            if delayMinutes > 0 { return "Delayed \(FlightClock.delayText(delayMinutes))" }
            // Same line the app draws (`Flight.isSoon`): "On Time" is only a
            // quote inside the day before, when the operator is being asked.
            return effectiveDeparture.timeIntervalSince(date) < 24 * 3600 ? "On Time" : "Scheduled"
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
        effectiveDeparture.timeIntervalSince(.now)
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
        case estimatedArrival, departureTZ, arrivalTZ, updatedAt, actualDeparture
        case estimatedTakeoff, groundState, groundObservedAt, taxiStartedAt
        case lastSeenOnGround, taxiPriorMinutes
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
        actualDeparture = try c.decodeIfPresent(Date.self, forKey: .actualDeparture)
        estimatedTakeoff = try c.decodeIfPresent(Date.self, forKey: .estimatedTakeoff)
        groundState = try c.decodeIfPresent(String.self, forKey: .groundState)
        groundObservedAt = try c.decodeIfPresent(Date.self, forKey: .groundObservedAt)
        taxiStartedAt = try c.decodeIfPresent(Date.self, forKey: .taxiStartedAt)
        lastSeenOnGround = try c.decodeIfPresent(Date.self, forKey: .lastSeenOnGround)
        taxiPriorMinutes = try c.decodeIfPresent(Int.self, forKey: .taxiPriorMinutes)
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
        try c.encodeIfPresent(actualDeparture, forKey: .actualDeparture)
        try c.encodeIfPresent(estimatedTakeoff, forKey: .estimatedTakeoff)
        try c.encodeIfPresent(groundState, forKey: .groundState)
        try c.encodeIfPresent(groundObservedAt, forKey: .groundObservedAt)
        try c.encodeIfPresent(taxiStartedAt, forKey: .taxiStartedAt)
        try c.encodeIfPresent(lastSeenOnGround, forKey: .lastSeenOnGround)
        try c.encodeIfPresent(taxiPriorMinutes, forKey: .taxiPriorMinutes)
    }
}
