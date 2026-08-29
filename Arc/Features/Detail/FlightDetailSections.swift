import SwiftUI
import SwiftData

// MARK: - Shared

private func sectionTitle(_ text: String) -> some View {
    Text(text).font(.system(size: 22, weight: .bold))
        .frame(maxWidth: .infinity, alignment: .leading)
}

private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
}

// MARK: - Good to Know

/// Only facts worth knowing: no card at all beats a card of filler.
///
/// The old default row claimed "No known disruptions — X and Y operating
/// normally", asserting airport-level knowledge no feed provides, and its
/// delay rows repeated what the status banner already says. What remains is
/// real: cancellation/diversion (worth repeating — it changes everything),
/// the timezone math, and which side of the aircraft the sun will be on —
/// computed from the route and the clock, not guessed.
struct GoodToKnowSection: View {
    let flight: Flight

    private var sunTip: SunSide.Tip? {
        // "You'll fly into the sunset" is a plane's phenomenon, and a hand-
        // typed leg has no coordinates to compute it from anyway.
        guard !flight.isCompleted, flight.mode == .air, flight.hasRoute else { return nil }
        return SunSide.tip(
            dep: .init(latitude: flight.departureLat, longitude: flight.departureLon),
            arr: .init(latitude: flight.arrivalLat, longitude: flight.arrivalLon),
            departure: flight.effectiveDeparture, arrival: flight.effectiveArrival)
    }

    var body: some View {
        let disrupted = flight.status == .cancelled || flight.status == .diverted
        let note = flight.disruptionNote?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tip = sunTip
        if disrupted || note?.isEmpty == false || flight.bookingURL != nil
            || flight.timezoneDeltaHours != 0 || tip != nil {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Good to Know")
                if disrupted { card { disruptionRow } }
                // The operator's own words — ferry and rail feeds publish prose
                // notices, not per-leg delay figures, so this note IS the
                // disruption channel for those modes. Quote it verbatim.
                if let note, !note.isEmpty { card { operatorNoticeRow(note) } }
                if let url = flight.bookingURL.flatMap(URL.init(string:)) {
                    card {
                        Link(destination: url) {
                            HStack(spacing: 10) {
                                Image(systemName: "ticket").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Manage Booking")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Text(url.host() ?? "Operator website")
                                        .font(.system(size: 13)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                if flight.timezoneDeltaHours != 0 {
                    card {
                        HStack(spacing: 10) {
                            Image(systemName: "clock.arrow.2.circlepath").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                let d = flight.timezoneDeltaHours
                                Text("\(d > 0 ? "+" : "")\(d) Hour Timezone Change")
                                    .font(.system(size: 15, weight: .semibold))
                                Text("\(flight.effectiveArrTimeLocal) arrival is \(flight.effectiveArrivalInDepartureLocal) \(flight.departureCity) time")
                                    .font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let tip {
                    card {
                        HStack(spacing: 10) {
                            Image(systemName: tip.icon).foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tip.title).font(.system(size: 15, weight: .semibold))
                                Text(tip.detail).font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var disruptionRow: some View {
        let cancelled = flight.status == .cancelled
        let noun = flight.mode == .air ? "Flight" : "Service"
        HStack(spacing: 10) {
            Image(systemName: cancelled ? "xmark.seal.fill" : "arrow.triangle.turn.up.right.diamond.fill")
                .foregroundStyle(ArcTheme.late)
            VStack(alignment: .leading, spacing: 2) {
                Text(cancelled ? "\(noun) cancelled" : "\(noun) diverted")
                    .font(.system(size: 15, weight: .semibold))
                Text(cancelled
                     ? "\(flight.departureIATA) → \(flight.arrivalIATA) will not operate as scheduled"
                     : flight.mode == .air
                         ? "This flight was routed to a different airport"
                         : "This service was routed to a different \(flight.mode == .sea ? "port" : "station")")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }

    /// Prose from the operator's own disruption feed, quoted verbatim — Arc
    /// has no per-leg delay figure for these modes, so editorializing on top
    /// of the notice would be invention.
    private func operatorNoticeRow(_ note: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.bubble.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Operator Notice")
                    .font(.system(size: 15, weight: .semibold))
                Text(note)
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Where's My Plane

/// The aircraft's story, not its portrait: which tail, what Arc predicts, and
/// the legs the plane has flown today. The decorative silhouette is gone —
/// this card earns its space with information.
struct WheresMyPlaneSection: View {
    let flight: Flight
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Where's My Plane?").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                Text(flight.aircraftType ?? "Aircraft").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 10) {
                thisFlightRow

                if flight.showsPrediction, let reason = flight.predictionReason {
                    predictionRow(minutes: flight.predictedDelayMinutes, reason: reason)
                }

                if !flight.rotationLegs.isEmpty {
                    Divider().background(.white.opacity(0.2))
                    Text("Earlier legs of this aircraft · latest first")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .textCase(.uppercase)
                    // Most relevant first: the immediate inbound, then the
                    // legs that fed it, walking back through the day.
                    ForEach(Array(flight.rotationLegs.reversed().enumerated()), id: \.offset) { _, leg in
                        rotationLegRow(leg)
                    }
                } else if let inboundNumber = flight.inboundFlightNumber {
                    Divider().background(.white.opacity(0.2))
                    inboundLegRow(number: inboundNumber)
                } else if flight.inboundChecked && flight.aircraftRegistration != nil {
                    Divider().background(.white.opacity(0.2))
                    HStack(spacing: 10) {
                        Image(systemName: "questionmark.circle").foregroundStyle(.white.opacity(0.7))
                        Text("No earlier legs found for this aircraft today")
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            .padding(16)
            .background(Color(.systemBackground).opacity(0.15))
        }
        .background(
            // The card is Arc's own inference (rotation chain + knock-on
            // prediction), so it wears the smart ramp — deepened coral→magenta
            // rather than the sticker-bright text gradient, keeping the white
            // type legible at card scale.
            LinearGradient(colors: [Color(red: 0.82, green: 0.36, blue: 0.22),
                                    Color(red: 0.58, green: 0.18, blue: 0.54)],
                           startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var thisFlightRow: some View {
        HStack(spacing: 10) {
            Image(systemName: flight.isActive ? "airplane" : "arrow.down.circle")
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(thisFlightTitle)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Text(statusText).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
            }
            Spacer()
            if let reg = flight.aircraftRegistration {
                Text(reg).font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    /// Arc's own knock-on prediction, shown alongside — never replacing —
    /// the airline's official time.
    private func predictionRow(minutes: Int, reason: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                SmartLabel(text: "Arc predicts ~\(minutes)m late")
                Text(reason + " — the airline still shows \(flight.delayMinutes > 0 ? "+\(flight.delayMinutes)m" : "on time").")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }

    private func rotationLegRow(_ leg: RotationLeg) -> some View {
        // A minute heartbeat: "Departure not yet confirmed" is a claim about
        // the clock, and the card can sit open across the moment it changes.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let d = RotationLegDisplay.make(leg, now: context.date)
            HStack(spacing: 10) {
                // The ONE tick in the row, and only once the leg has landed.
                Image(systemName: d.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(glyphColor(d.phase))
                    .frame(width: 18)
                    .symbolEffect(.pulse, options: .repeating, isActive: d.phase == .airborne)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(leg.flightNumber).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        Text("\(leg.depIATA) → \(leg.arrIATA)").font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                    }
                    Text(d.statusText)
                        .font(.system(size: 12))
                        .foregroundStyle(d.delayMinutes > 0 ? delayColor(d.delayMinutes) : .white.opacity(0.65))
                }
                Spacer()
                if let time = d.timeText {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(time)
                            .font(.system(size: 14, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                        Text(d.timeCaption)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                            .textCase(.uppercase)
                    }
                }
            }
        }
    }

    private func glyphColor(_ phase: RotationLegDisplay.Phase) -> Color {
        switch phase {
        case .landed: .green
        case .cancelled: ArcTheme.late
        case .overdue: .white.opacity(0.55)
        case .airborne, .scheduled: .white.opacity(0.9)
        }
    }

    /// Yellow up to a quarter hour, orange beyond — same thresholds the
    /// prediction uses to decide a delay is worth mentioning.
    private func delayColor(_ minutes: Int) -> Color {
        minutes > 15 ? .orange : .yellow
    }

    /// Legacy single-inbound row (data recorded before the chain existed).
    /// The model has no status for it, only a scheduled arrival and lateness,
    /// so the clock decides the verb — never a tick it can't back up.
    private func inboundLegRow(number: String) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let delay = flight.inboundDelayMinutes
            let due = flight.inboundArrivalTime.map { $0.addingTimeInterval(Double(delay) * 60) }
            let past = due.map { context.date > $0.addingTimeInterval(20 * 60) } ?? false
            // The inbound lands where this flight departs — that airport's clock.
            let zone = ReferenceData.shared.timezone(flight.departureIATA) ?? .current
            HStack(spacing: 10) {
                Image(systemName: past ? "questionmark.circle" : "arrow.turn.down.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(past ? 0.55 : 0.9))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(number).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        if let route = flight.inboundRoute {
                            Text(route).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    Text((past ? "Landing not yet confirmed" : "Inbound to \(flight.departureIATA)")
                         + (delay > 0 ? " · \(delay)m late" : ""))
                        .font(.system(size: 12))
                        .foregroundStyle(delay > 0 ? delayColor(delay) : .white.opacity(0.65))
                }
                Spacer()
                if let due {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(due.formatted(Date.FormatStyle(timeZone: zone).hour().minute()))
                            .font(.system(size: 14, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                        Text("due").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5)).textCase(.uppercase)
                    }
                }
            }
        }
    }

    /// The aircraft card's own headline. "In the air" is a claim like any
    /// other: while the aircraft is on the ground — taxiing, or waiting for a
    /// wheels-up nobody has reported — it must not be made.
    private var thisFlightTitle: String {
        switch flight.departurePhase {
        case .taxiing: return flight.mode == .air ? "This flight — taxiing" : "This Flight"
        case .departing: return "This flight — departing"
        case .presumedAirborne:
            return flight.mode == .air ? "This flight — takeoff unconfirmed" : "This Flight"
        case .airborne:
            return flight.isActive ? "This flight — in the air" : "This Flight"
        case .beforeDeparture: return "This Flight"
        }
    }

    private var statusText: String {
        if case .taxiing = flight.departurePhase { return "On the ground, moving" }
        if flight.isActive, flight.departurePhase == .presumedAirborne {
            return flight.mode == .air
                ? DeparturePhase.takeoffUnconfirmedSubtitle
                : "Tracking live position"
        }
        if flight.isActive { return "Tracking live position" }
        if flight.status == .cancelled { return "This flight was cancelled" }
        if flight.status == .diverted { return "This flight was diverted" }
        if !flight.isUpcoming { return "This flight has already flown" }

        // No registration yet — airline hasn't assigned a tail
        if flight.aircraftRegistration == nil || flight.aircraftRegistration?.isEmpty == true {
            let hoursOut = flight.scheduledDeparture.timeIntervalSince(.now) / 3600
            if hoursOut > 24 {
                return "Aircraft typically assigned 1–24h before departure"
            }
            return "Aircraft not yet assigned by airline"
        }

        if !flight.inboundChecked { return "Checking previous rotation…" }
        if flight.inboundFlightNumber == nil { return "No prior rotation found for this tail" }
        if flight.inboundDelayMinutes > 0 { return "Inbound aircraft running \(flight.inboundDelayMinutes)m late" }
        return "Inbound aircraft on schedule"
    }

}

// MARK: - Detailed Timetable

struct DetailedTimetableSection: View {
    let flight: Flight
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                sectionTitle("Detailed Timetable")
                Text(flight.status == .landed ? "Scheduled and Actual" : "Scheduled and Estimated")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            card {
                VStack(spacing: 14) {
                    groupHeader("DEPART")
                    timeRow(flight.mode == .air ? "Gate Departure" : "Departure", scheduled: flight.depTimeLocal,
                            estimated: flight.departureChanged ? flight.effectiveDepTimeLocal : "--")
                    Divider()
                    groupHeader("ARRIVE")
                    timeRow(flight.mode == .air ? "Gate Arrival" : "Arrival", scheduled: flight.arrTimeLocal,
                            estimated: flight.arrivalChanged ? flight.effectiveArrTimeLocal : "--")
                    Divider()
                    groupHeader("TOTALS")
                    plainRow(flight.mode == .air ? "Air Time" : "Travel Time", flight.durationFormatted)
                    if flight.hasRoute { plainRow("Distance", flight.distanceFormatted) }
                    // Calibration in public: once the flight has flown, show
                    // what Arc predicted at departure next to what happened.
                    // A prediction you can't check afterwards is marketing.
                    if flight.isCompleted, flight.predictedDelayAtDeparture > 0 {
                        Divider()
                        HStack {
                            SmartLabel(text: "Arc predicted", size: 15)
                            Spacer()
                            Text("+\(flight.predictedDelayAtDeparture)m · actual \(flight.delayMinutes > 0 ? "+\(flight.delayMinutes)m" : "on time")")
                                .font(.system(size: 15)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func groupHeader(_ t: String) -> some View {
        HStack {
            Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary).tracking(0.5)
            Spacer()
            Text("Scheduled").font(.system(size: 12)).foregroundStyle(.tertiary).frame(width: 80, alignment: .trailing)
            Text(flight.status == .landed ? "Actual" : "Estimated")
                .font(.system(size: 12)).foregroundStyle(.tertiary).frame(width: 80, alignment: .trailing)
        }
    }
    private func timeRow(_ label: String, scheduled: String, estimated: String) -> some View {
        HStack {
            Text(label).font(.system(size: 15, weight: .semibold))
            Spacer()
            Text(scheduled).font(.system(size: 15)).frame(width: 80, alignment: .trailing)
            Text(estimated).font(.system(size: 15)).foregroundStyle(estimated == "--" ? .secondary : .primary)
                .frame(width: 80, alignment: .trailing)
        }
    }
    private func plainRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 15, weight: .semibold))
            Spacer()
            Text(value).font(.system(size: 15)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Airline info

struct AirlineInfoSection: View {
    let flight: Flight
    private var airline: AirlineRef? { ReferenceData.shared.airline(flight.airlineCode) }
    var body: some View {
        if flight.mode == .air {
            airlineCard
        } else if !operatorName.isEmpty || flight.vesselName != nil {
            operatorCard
        }
    }

    private var airlineCard: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    AirlineLogoView(iata: flight.airlineCode, size: 30)
                    Text(airline?.name ?? flight.airline).font(.system(size: 20, weight: .bold))
                }
                HStack {
                    infoCol("ATC Callsign", airline?.callsign ?? "—")
                    infoCol("ICAO", airline?.icao ?? flight.airlineICAO)
                    infoCol("IATA", flight.airlineCode)
                }
            }
        }
    }

    private var operatorName: String { flight.airline }

    /// The rail/sea counterpart: callsigns and IATA codes are aviation
    /// registry facts with no analogue here — the operator (and for a
    /// sailing, the vessel) is the whole identity.
    private var operatorCard: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    TripLogoView(mode: flight.mode, logoURL: flight.operatorLogoURL, size: 30)
                    Text(operatorName.isEmpty ? flight.mode.operatorNoun : operatorName)
                        .font(.system(size: 20, weight: .bold))
                }
                HStack {
                    infoCol(flight.mode.operatorNoun, operatorName)
                    if let vessel = flight.vesselName, !vessel.isEmpty {
                        infoCol("Vessel", vessel)
                    }
                    infoCol("Service", flight.flightNumber)
                }
            }
        }
    }
    private func infoCol(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).font(.system(size: 15, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Route history

struct RouteHistorySection: View {
    let flight: Flight
    @Query private var all: [Flight]

    private var onRoute: [Flight] {
        // Same mode as well as same codes: a rail leg's "BER" is Berlin Hbf,
        // and mixing it into a BER→MUC flight history would count a train as
        // a flight on that route.
        all.filter { $0.status == .landed && $0.mode == flight.mode
            && $0.departureIATA == flight.departureIATA && $0.arrivalIATA == flight.arrivalIATA }
    }
    /// Punctuality from the user's own completed flights — data no API sells,
    /// and it compounds with every trip the family takes.
    private var punctualityLine: String? {
        // A timetable-only leg carries delay 0 because nobody measured it,
        // not because it ran to time — it can't vote on punctuality.
        let reported = onRoute.filter { $0.dataTier.reportsPunctuality }
        guard reported.count >= 2 else { return nil }
        let delays = reported.map(\.delayMinutes).sorted()
        let onTime = delays.filter { $0 <= 15 }.count
        let median = delays[delays.count / 2]
        let medianText = median > 0 ? "median +\(median)m" : "typically on time"
        return "On time \(onTime) of \(reported.count) · \(medianText)"
    }

    var body: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text("My History on This Route").font(.system(size: 18, weight: .bold))
                Text("\(flight.departureIATA) → \(flight.arrivalIATA)").font(.system(size: 13)).foregroundStyle(.secondary)
                HStack {
                    stat(flight.mode == .air ? "Flights" : "Trips", "\(onRoute.count)")
                    // Legs without coordinates (hand-entered stations, unplotted
                    // ports) have no distance — "0 km" would be a made-up fact.
                    let km = Int(onRoute.map(\.distanceKm).reduce(0, +))
                    if km > 0 { stat("Distance", "\(km) km") }
                    stat(flight.mode == .air ? "Flight Time" : "Travel Time",
                         "\(Int(onRoute.map(\.duration).reduce(0,+)) / 3600)h")
                }
                if let punctualityLine {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.badge.checkmark")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(punctualityLine).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Notes

struct NotesSection: View {
    let flight: Flight
    var onEdit: () -> Void
    var body: some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                Text("Notes").font(.system(size: 18, weight: .bold))
                Button(action: onEdit) {
                    Text(flight.notes.isEmpty ? "Tap to Edit" : flight.notes)
                        .font(.system(size: 15))
                        .foregroundStyle(flight.notes.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Pillar 3.2: Live Baggage Carousel & Handoff

/// The arrival belt, when the airline has actually assigned one.
///
/// This used to claim a great deal more: a green CONFIRMED badge, a "LIVE"
/// heading, a baggage status alternating between "Offloading from Cargo Hold"
/// and "Bags On Carousel (~12m)", and "Exit Door 4 (~3m wait)". None of that is
/// in any feed we have — it showed "offloading" for a flight that had not
/// departed yet. The terminal and belt come from the airline; everything else
/// has gone, and the card now looks like the ordinary fact it is.
struct BaggageCarouselSection: View {
    let flight: Flight
    let belt: String

    /// Omitted when unknown rather than filled in as "Main", which was a guess
    /// dressed as a fact.
    private var terminal: String? {
        guard let value = flight.arrivalTerminal, !value.isEmpty else { return nil }
        return value
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "suitcase.cart.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("BAGGAGE RECLAIM")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                Text(terminal.map { "Terminal \($0) · Belt \(belt)" } ?? "Belt \(belt)")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
