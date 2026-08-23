import WidgetKit
import SwiftUI

// MARK: - Timeline Provider

struct NextFlightProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextFlightEntry {
        NextFlightEntry(date: .now, flight: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (NextFlightEntry) -> Void) {
        let flights = WidgetData.loadFlights()
        let next = flights.first { $0.isUpcoming || $0.isActive }
        completion(NextFlightEntry(date: .now, flight: next ?? .sample))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<NextFlightEntry>) -> Void) {
        Task.detached {
            // The widget refreshes its lead leg against the Worker itself —
            // the app is usually closed exactly when the home screen matters.
            let flights = await WidgetRefresh.refreshed(WidgetData.loadFlights())
            completion(Self.timeline(for: flights, now: .now))
        }
    }

    static func timeline(for flights: [WidgetFlight], now: Date) -> Timeline<NextFlightEntry> {
        // Active or upcoming first; failing that, a flight landed within the
        // last 30 min still gets shown (in its landed look) before the widget
        // gives up and shows the empty state.
        let next = flights.first { $0.isCurrent(at: now) }
            ?? flights.first { $0.phase(at: now) == .landed && now < $0.effectiveArrival.addingTimeInterval(30 * 60) }

        // Widget views are rendered ONCE per entry, at timeline-build time —
        // anything computed from Date.now in the view is frozen into that
        // render. Live movement comes from two places instead: auto-updating
        // date text/progress styles (system-animated, no process needed), and
        // extra entries at the exact moments the *layout* changes phase
        // (departure → in-flight look, arrival → landed look, arrival+30m →
        // done). Entries are pre-scheduled local renders, so all of this
        // works with the app closed AND the device offline.
        var entries = [NextFlightEntry(date: now, flight: next, all: flights)]
        if let f = next {
            // Gate time, expected wheels-up, arrival — see layoutFlips. The
            // middle one is not the gate time plus a constant: it is
            // off-block plus what this airport's taxi actually takes, which
            // is the difference between a home screen that announces "In
            // Air" to someone in an ATC hold and one that doesn't.
            for moment in f.layoutFlips(after: now) {
                entries.append(NextFlightEntry(date: moment, flight: f, all: flights))
            }
            // Grace expired: hand over to whatever comes next (or the empty
            // state) instead of re-rendering the landed leg forever.
            let done = f.effectiveArrival.addingTimeInterval(30 * 60 + 1)
            if done > now {
                let following = flights.first { $0.id != f.id && $0.isCurrent(at: done) }
                entries.append(NextFlightEntry(date: done, flight: following, all: flights))
            }
        }
        // Ask to be reloaded (and re-fetch) often while a leg is live or
        // imminent — that's when gates and delays move — and rarely otherwise.
        // iOS applies its own budget on top; this is the request, not a promise.
        let minutes: Int
        if let f = next, f.isActive || f.scheduledDeparture.timeIntervalSince(now) < 3 * 3600 {
            minutes = 5
        } else if let f = next, f.scheduledDeparture.timeIntervalSince(now) < 24 * 3600 {
            minutes = 15
        } else {
            minutes = 60
        }
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: minutes, to: now)!
        return Timeline(entries: entries.sorted { $0.date < $1.date }, policy: .after(nextUpdate))
    }
}

struct NextFlightEntry: TimelineEntry {
    let date: Date
    let flight: WidgetFlight?
    /// The full snapshot at build time, so the medium view renders the same
    /// (refreshed) facts as the small one instead of re-reading the App Group.
    var all: [WidgetFlight] = []
}

// MARK: - Small Widget (Next Flight Countdown)

struct NextFlightSmallView: View {
    let entry: NextFlightEntry

    var body: some View {
        if let flight = entry.flight {
            // Phase from the ENTRY's date, not from Date.now or the stored
            // status — that's what makes pre → in-flight → landed flips
            // happen automatically (see the timeline provider).
            let phase = flight.phase(at: entry.date)
            VStack(alignment: .leading, spacing: 6) {
                // Countdown — live minute-precision text is system-animated:
                // it keeps ticking on the lock/home screen with no app process
                // running, unlike the old pre-rendered countdownText string.
                Group {
                    // A cancelled trip has no countdown to run, whatever the
                    // clock says — it says so instead.
                    if flight.isDisrupted {
                        Text(flight.terminalLabel)
                    } else {
                        switch phase {
                        // .relative is minute-precision (no seconds column) and
                        // the one live style every render path supports. The
                        // landed timeline entry retires the in-flight countdown
                        // before it could start counting up past the ETA.
                        case .inFlight: Text(flight.effectiveArrival, style: .relative)
                        case .upcoming: Text(flight.effectiveDeparture, style: .relative)
                        case .landed: Text(flight.terminalLabel)
                        }
                    }
                }
                .font(.system(size: 22, weight: .heavy).monospacedDigit())
                .foregroundStyle(countdownColor(flight, phase: phase))
                .lineLimit(1)
                .minimumScaleFactor(0.6)

                // Route. A cancelled trip reached no arrival, so it must never
                // wear the green tick that means "you got there".
                HStack(spacing: 4) {
                    Text(flight.departureIATA)
                        .font(.system(size: 15, weight: .heavy))
                    // The tick means "you got there" — only the source can
                    // say so; the clock passing the ETA merely says "should
                    // have", which the label above hedges as "Arriving soon".
                    Image(systemName: flight.isDisrupted ? "xmark"
                          : flight.status == "landed" ? "checkmark" : "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(flight.isDisrupted ? .red
                                         : flight.status == "landed" && flight.reportsPunctuality
                                             ? .green : .secondary)
                    Text(flight.arrivalIATA)
                        .font(.system(size: 15, weight: .heavy))
                }

                // Flight number
                Text(flight.flightNumber)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                // In-flight: system-animated progress bar (moves offline too)
                if phase == .inFlight {
                    ProgressView(
                        timerInterval: min(flight.effectiveDeparture, flight.effectiveArrival - 60)...flight.effectiveArrival,
                        countsDown: false,
                        label: { EmptyView() },
                        currentValueLabel: { EmptyView() }
                    )
                    .progressViewStyle(.linear)
                    .tint(flight.reportsPunctuality ? .green : .secondary)
                }

                Spacer()

                // Status. Arc's own prediction wears Arc's mark instead of a
                // status dot — the dot is how the widget quotes the airline,
                // and this number is not the airline's.
                if flight.showsPrediction, phase == .upcoming {
                    IntelligenceBadge(text: "Arc +\(flight.predictedDelayMinutes)m", size: 11)
                } else {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusColor(flight, phase: phase))
                            .frame(width: 6, height: 6)
                        Text(flight.statusText(phase: phase, at: entry.date))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                // Where to stand. Trains have platforms and ferries have berths,
                // so the word comes from the mode — a train "Gate 7" is the kind
                // of small wrongness that makes the widget feel foreign.
                if let gate = flight.departureGate, phase == .upcoming, !flight.isDisrupted {
                    Text("\(flight.mode.boardingPointLabel) \(gate)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(statusColor(flight, phase: phase))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(ArcDeepLink.flight(widget: flight))
        } else {
            VStack(spacing: 8) {
                Image(systemName: "airplane")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                // "Trips", not "flights": Arc tracks trains and ferries too, and
                // an empty widget is exactly where it shouldn't narrow itself.
                Text("No trips")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func countdownColor(_ flight: WidgetFlight, phase: WidgetFlight.Phase) -> Color {
        if flight.isDisrupted { return .red }
        // Green is the widget saying "this ran to plan", and orange is a delay
        // figure — neither is available for a leg whose source reports no
        // punctuality. The countdown itself is a fact in any tier, though, so it
        // keeps its normal weight; only the claims are withheld.
        if phase != .upcoming { return flight.reportsPunctuality ? .green : .secondary }
        if flight.reportsPunctuality, flight.showsPrediction || flight.delayMinutes > 0 {
            return .orange
        }
        let hours = flight.timeUntilDeparture / 3600
        if hours < 2 { return .orange }   // soon is a clock fact, not a claim
        return .primary
    }

    private func statusColor(_ flight: WidgetFlight, phase: WidgetFlight.Phase) -> Color {
        if flight.isDisrupted { return .red }
        if !flight.reportsPunctuality { return .secondary }
        // Green is "a source says it left" — withheld while the departure is
        // unconfirmed, whether Arc is hedging or merely presuming.
        if !flight.departurePhase(at: entry.date).isConfirmed,
           flight.phase(at: entry.date) == .inFlight { return .secondary }
        if phase != .upcoming { return .green }
        if flight.showsPrediction || flight.delayMinutes > 0 { return .orange }
        return .green
    }
}

// MARK: - Medium Widget (Next trip, in full — then what follows)

/// One trip in full — status, times at both ends in their local zones, the
/// gate/terminal/belt a traveller is actually walking towards, and a live
/// countdown — followed by up to two compact rows for what comes next. The
/// previous layout gave every leg the same 30-point row, so the one that
/// mattered right now got no more space than a flight three weeks out.
struct NextFlightMediumView: View {
    let entry: NextFlightEntry

    /// Same set the small widget draws from, so the two never disagree about
    /// what "your flights" are: live legs first, then one that landed within
    /// the last 30 minutes (its belt and arrival gate still matter).
    private var flights: [WidgetFlight] {
        let all = entry.all.isEmpty ? WidgetData.loadFlights() : entry.all
        let live = all.filter { $0.isUpcoming || $0.isActive }
        // A flight past its ETA is still stored as `active` until the app next
        // runs, so it lands in BOTH sets — dedupe by id, or ForEach gets two
        // rows claiming the same identity.
        let justLanded = all.filter {
            $0.phase(at: entry.date) == .landed
                && entry.date < $0.effectiveArrival.addingTimeInterval(30 * 60)
        }
        var seen = Set<String>()
        return (live + justLanded).filter { seen.insert($0.id).inserted }.prefix(3).map { $0 }
    }

    var body: some View {
        if let hero = flights.first {
            let rest = Array(flights.dropFirst())
            // Every trip is its own card, so "how many flights is this?" needs
            // no reading. The hero card stretches to take whatever height the
            // mini cards leave — no dead air at the top or bottom.
            VStack(spacing: 6) {
                Link(destination: ArcDeepLink.flight(widget: hero)) {
                    heroCard(hero)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if !rest.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(rest, id: \.id) { flight in
                            Link(destination: ArcDeepLink.flight(widget: flight)) {
                                miniCard(flight)
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                        // One follow-up leg still gets a half-width card, so the
                        // rhythm doesn't change when a trip is added or removed.
                        if rest.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            HStack {
                Image(systemName: "airplane")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No upcoming trips")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Add a trip in Arc")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Cards sit on the widget's own tertiary fill; a step lighter/darker than
    /// that reads as a surface in both appearances without a hard edge.
    private var cardFill: some ShapeStyle { Color.primary.opacity(0.06) }

    // MARK: Hero

    @ViewBuilder
    private func heroCard(_ f: WidgetFlight) -> some View {
        let phase = f.phase(at: entry.date)
        VStack(alignment: .leading, spacing: 5) {
            // Row 1: identity ⟷ status
            HStack(spacing: 5) {
                Image(systemName: f.mode.symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(statusColor(f, phase: phase))
                Text(f.flightNumber)
                    .font(.system(size: 12, weight: .bold))
                if !f.airline.isEmpty {
                    // The brand, not the registered name — "Swiss" reads at
                    // widget scale where "Swiss International Air Lines" gets
                    // truncated to nothing useful.
                    Text("· \(shortAirline(f.airline))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 4)
                statusPill(f, phase: phase)
            }

            // Row 2: DEP time ── vehicle/progress ── ARR time
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(f.departureIATA)
                    .font(.system(size: 20, weight: .heavy))
                Text(f.depTimeLocal)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(f.reportsPunctuality && f.delayMinutes > 0 ? .orange : .secondary)
                Spacer(minLength: 6)
                if phase == .inFlight {
                    // System-animated — keeps filling with no process running.
                    ProgressView(
                        timerInterval: min(f.effectiveDeparture, f.effectiveArrival - 60)...f.effectiveArrival,
                        countsDown: false,
                        label: { EmptyView() },
                        currentValueLabel: { EmptyView() }
                    )
                    .progressViewStyle(.linear)
                    .tint(f.reportsPunctuality ? .green : .secondary)
                    .frame(maxWidth: 70)
                } else {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 6)
                Text(f.arrTimeLocal)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(f.reportsPunctuality && f.effectiveArrival > f.scheduledArrival.addingTimeInterval(60)
                                     ? .orange : .secondary)
                Text(f.arrivalIATA)
                    .font(.system(size: 20, weight: .heavy))
            }

            // Row 3: the countdown ⟷ where to go
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                countdownLine(f, phase: phase)
                Spacer(minLength: 6)
                whereToGo(f, phase: phase)
            }
        }
    }

    /// "Departs in 2 hr, 14 min" / "Arrives in 46 min" — .relative text is
    /// system-animated, so it counts with the app dead and the device offline.
    @ViewBuilder
    private func countdownLine(_ f: WidgetFlight, phase: WidgetFlight.Phase) -> some View {
        let color = countdownColor(f, phase: phase)
        HStack(spacing: 4) {
            if f.isDisrupted {
                Text(f.terminalLabel)
                    .font(.system(size: 13, weight: .heavy))
            } else {
                switch phase {
                case .upcoming:
                    Text("Departs in")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Text(f.effectiveDeparture, style: .relative)
                        .font(.system(size: 13, weight: .heavy).monospacedDigit())
                case .inFlight:
                    Text("\(f.mode.arrivingVerb == "Landing" ? "Lands" : "Arrives") in")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Text(f.effectiveArrival, style: .relative)
                        .font(.system(size: 13, weight: .heavy).monospacedDigit())
                case .landed:
                    Text(f.terminalLabel)
                        .font(.system(size: 13, weight: .heavy))
                }
            }
        }
        .foregroundStyle(color)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    /// The one physical fact for THIS phase: gate/terminal before departure,
    /// arrival gate/belt after. Never two rows saying the same thing.
    @ViewBuilder
    private func whereToGo(_ f: WidgetFlight, phase: WidgetFlight.Phase) -> some View {
        let parts: [String] = {
            guard !f.isDisrupted else { return [] }
            switch phase {
            case .upcoming:
                var p: [String] = []
                if let t = f.departureTerminal, !t.isEmpty { p.append("T\(t)") }
                if let g = f.departureGate, !g.isEmpty { p.append("\(f.mode.boardingPointLabel) \(g)") }
                return p
            case .inFlight, .landed:
                var p: [String] = []
                if let t = f.arrivalTerminal, !t.isEmpty { p.append("T\(t)") }
                if let g = f.arrivalGate, !g.isEmpty { p.append("\(f.mode.boardingPointLabel) \(g)") }
                if let b = f.baggageClaim, !b.isEmpty, f.mode == .air { p.append("Belt \(b)") }
                return p
            }
        }()
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.primary.opacity(0.07), in: Capsule())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } else if phase == .upcoming, !f.isDisrupted, f.mode.hasAirportOperations {
            Text("\(f.mode.boardingPointLabel) TBA")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
    }

    /// One coloured word: what the source says. Timetable-only legs name the
    /// source instead of claiming punctuality nobody published.
    @ViewBuilder
    private func statusPill(_ f: WidgetFlight, phase: WidgetFlight.Phase) -> some View {
        if f.showsPrediction, phase == .upcoming {
            IntelligenceBadge(text: "Arc +\(f.predictedDelayMinutes)m", size: 11)
        } else {
            let color = statusColor(f, phase: phase)
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(f.statusText(phase: phase, at: entry.date))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(color)
            }
            .lineLimit(1)
        }
    }

    /// The first word or two of a carrier's registered name — what people
    /// call the airline. Deliberately dumb: strips the corporate tail rather
    /// than maintaining a brand table the widget can't keep current.
    private func shortAirline(_ name: String) -> String {
        let tails = ["International Air Lines", "International Airlines", "Airlines", "Air Lines",
                     "Airways", "Aviation", "Group", "AG", "S.A.", "Ltd", "Inc", "plc"]
        var s = name.trimmingCharacters(in: .whitespaces)
        for t in tails where s.hasSuffix(" " + t) {
            let cut = s.dropLast(t.count + 1)
            if cut.count >= 3 { s = String(cut) }
        }
        return s
    }

    // MARK: Mini cards

    /// Half-width card for a later leg: route + number on top, the day and
    /// the one fact worth knowing (Arc's prediction, a delay, the gate, or the
    /// data source) underneath.
    @ViewBuilder
    private func miniCard(_ f: WidgetFlight) -> some View {
        let phase = f.phase(at: entry.date)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: f.mode.symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(f.departureIATA)
                    .font(.system(size: 13, weight: .heavy))
                Image(systemName: "arrow.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.tertiary)
                Text(f.arrivalIATA)
                    .font(.system(size: 13, weight: .heavy))
                Spacer(minLength: 2)
                Text(f.flightNumber)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            HStack(spacing: 4) {
                Text(whenText(f))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                if f.showsPrediction, phase == .upcoming {
                    IntelligenceBadge(text: "Arc +\(f.predictedDelayMinutes)m", size: 10)
                } else if f.isDisrupted {
                    Text(f.terminalLabel).font(.system(size: 10, weight: .bold)).foregroundStyle(.red)
                } else if f.reportsPunctuality, f.delayMinutes > 0 {
                    Text("+\(f.delayMinutes)m").font(.system(size: 10, weight: .bold)).foregroundStyle(.orange)
                } else if let g = f.departureGate, !g.isEmpty, phase == .upcoming {
                    Text("\(f.mode.boardingPointLabel) \(g)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(f.reportsPunctuality ? Color.green : .secondary)
                        .lineLimit(1)
                } else if let q = f.dataTier.qualifier, phase == .upcoming {
                    Text(q).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// "Today 17:22" / "Tomorrow 19:45" / "Sun 20 Sep" — a later leg is placed
    /// in the day, not counted down; a countdown of "16 hrs, 46 min" tells you
    /// nothing you can plan around.
    private func whenText(_ f: WidgetFlight) -> String {
        var cal = Calendar.current
        let dep = f.effectiveDeparture
        let tz = f.departureTZ.flatMap(TimeZone.init(identifier:)) ?? .current
        // "Today" on the AIRPORT's calendar, matching the airport-local time
        // printed next to it — a Tokyo 01:30 is not "Today" for a Zurich phone.
        cal.timeZone = tz
        if cal.isDateInToday(dep) { return "Today \(f.depTimeLocal)" }
        if cal.isDateInTomorrow(dep) { return "Tmrw \(f.depTimeLocal)" }
        let fmt = DateFormatter()
        fmt.timeZone = tz
        fmt.dateFormat = "EEE d MMM"
        return fmt.string(from: dep)
    }

    // MARK: Colours

    private func countdownColor(_ flight: WidgetFlight, phase: WidgetFlight.Phase) -> Color {
        if flight.isDisrupted { return .red }
        if phase != .upcoming { return flight.reportsPunctuality ? .green : .secondary }
        return flight.reportsPunctuality && (flight.showsPrediction || flight.delayMinutes > 0)
            ? .orange : .primary
    }

    private func statusColor(_ flight: WidgetFlight, phase: WidgetFlight.Phase) -> Color {
        if flight.isDisrupted { return .red }
        if !flight.reportsPunctuality { return .secondary }
        // Green is "a source says it left" — withheld while the departure is
        // unconfirmed, whether Arc is hedging or merely presuming.
        if !flight.departurePhase(at: entry.date).isConfirmed,
           flight.phase(at: entry.date) == .inFlight { return .secondary }
        if phase != .upcoming { return .green }
        if flight.showsPrediction || flight.delayMinutes > 0 { return .orange }
        return .green
    }
}

// MARK: - Widget Definition

struct NextFlightWidget: Widget {
    let kind = "NextFlightWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextFlightProvider()) { entry in
            Group {
                if #available(iOSApplicationExtension 17.0, *) {
                    NextFlightWidgetEntryView(entry: entry)
                        .containerBackground(.fill.tertiary, for: .widget)
                        // The cards carry their own inner air; the system's
                        // 16pt on top of that left a dead band above and below.
                        .modifier(MediumInsets())
                } else {
                    NextFlightWidgetEntryView(entry: entry)
                        .padding()
                        .background()
                }
            }
        }
        .contentMarginsDisabled()
        .configurationDisplayName("Next Flight")
        .description("Countdown to your next flight with gate and status.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// 10pt content margins on the medium family, system default elsewhere.
struct MediumInsets: ViewModifier {
    @Environment(\.widgetFamily) private var family
    func body(content: Content) -> some View {
        // Content margins are disabled at the configuration level, so the
        // small family gets the system's usual 16pt back here.
        content.padding(family == .systemMedium ? 10 : 16)
    }
}

struct NextFlightWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: NextFlightEntry

    var body: some View {
        switch family {
        case .systemSmall:
            NextFlightSmallView(entry: entry)
        case .systemMedium:
            NextFlightMediumView(entry: entry)
        default:
            NextFlightSmallView(entry: entry)
        }
    }
}

// MARK: - Sample Data

extension WidgetFlight {
    static let sample = WidgetFlight(
        id: "sample",
        flightNumber: "LX17",
        airline: "Swiss",
        departureIATA: "ZRH",
        arrivalIATA: "JFK",
        departureCity: "Zurich",
        arrivalCity: "New York",
        scheduledDeparture: Date.now.addingTimeInterval(3 * 3600),
        scheduledArrival: Date.now.addingTimeInterval(12 * 3600),
        status: "scheduled",
        delayMinutes: 0,
        departureGate: "A32",
        progress: 0
    )
}
