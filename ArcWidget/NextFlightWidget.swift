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

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextFlightEntry>) -> Void) {
        let flights = WidgetData.loadFlights()
        // Active or upcoming first; failing that, a flight landed within the
        // last 30 min still gets shown (in its landed look) before the widget
        // gives up and shows the empty state.
        let next = flights.first { $0.isUpcoming || $0.isActive }
            ?? flights.first { $0.phase(at: .now) == .landed && Date.now < $0.effectiveArrival.addingTimeInterval(30 * 60) }

        // Widget views are rendered ONCE per entry, at timeline-build time —
        // anything computed from Date.now in the view is frozen into that
        // render. Live movement comes from two places instead: auto-updating
        // date text/progress styles (system-animated, no process needed), and
        // extra entries at the exact moments the *layout* changes phase
        // (departure → in-flight look, arrival → landed look, arrival+30m →
        // done). Entries are pre-scheduled local renders, so all of this
        // works with the app closed AND the device offline.
        var entries = [NextFlightEntry(date: .now, flight: next)]
        if let f = next {
            let flips = [f.effectiveDeparture,
                         f.effectiveArrival,
                         f.effectiveArrival.addingTimeInterval(30 * 60 + 1)]
            for moment in flips where moment > .now {
                entries.append(NextFlightEntry(date: moment, flight: f))
            }
        }
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
        completion(Timeline(entries: entries.sorted { $0.date < $1.date }, policy: .after(nextUpdate)))
    }
}

struct NextFlightEntry: TimelineEntry {
    let date: Date
    let flight: WidgetFlight?
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
                    Image(systemName: flight.isDisrupted ? "xmark"
                          : phase == .landed ? "checkmark" : "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(flight.isDisrupted ? .red
                                         : phase == .landed && flight.reportsPunctuality
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
                        Text(flight.statusText(phase: phase))
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
        if phase != .upcoming { return .green }
        if flight.showsPrediction || flight.delayMinutes > 0 { return .orange }
        return .green
    }
}

// MARK: - Medium Widget (Upcoming Flights)

struct NextFlightMediumView: View {
    let entry: NextFlightEntry
    /// Same set the small widget draws from, so the two never disagree about
    /// what "your flights" are: live legs first, then one that landed within
    /// the last 30 minutes (its belt and arrival gate still matter).
    private var flights: [WidgetFlight] {
        let all = WidgetData.loadFlights()
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
        if flights.isEmpty {
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
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(flights.enumerated()), id: \.element.id) { idx, flight in
                    if idx > 0 {
                        Divider().padding(.vertical, 2)
                    }
                    Link(destination: ArcDeepLink.flight(widget: flight)) {
                        flightRow(flight)
                    }
                }
                if flights.count < 3 { Spacer() }
            }
        }
    }

    @ViewBuilder
    private func flightRow(_ flight: WidgetFlight) -> some View {
        let phase = flight.phase(at: entry.date)
        HStack(spacing: 10) {
            // Countdown — live .relative text: minute precision, no seconds
            Group {
                if flight.isDisrupted {
                    Text(flight.terminalLabel)
                } else {
                    switch phase {
                    case .inFlight: Text(flight.effectiveArrival, style: .relative)
                    case .upcoming: Text(flight.effectiveDeparture, style: .relative)
                    case .landed: Text(flight.terminalLabel)
                    }
                }
            }
            .font(.system(size: 12, weight: .heavy).monospacedDigit())
            .foregroundStyle(countdownColor(flight, phase: phase))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: 62, alignment: .leading)

            // Route
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(flight.departureIATA)
                        .font(.system(size: 13, weight: .heavy))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(flight.arrivalIATA)
                        .font(.system(size: 13, weight: .heavy))
                }
                Text(flight.flightNumber)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Status + gate
            VStack(alignment: .trailing, spacing: 1) {
                if phase == .inFlight {
                    // System-animated — keeps filling with no process running,
                    // unlike the old frozen-at-render GeometryReader bar.
                    ProgressView(
                        timerInterval: min(flight.effectiveDeparture, flight.effectiveArrival - 60)...flight.effectiveArrival,
                        countsDown: false,
                        label: { EmptyView() },
                        currentValueLabel: { EmptyView() }
                    )
                    .progressViewStyle(.linear)
                    .tint(flight.reportsPunctuality ? .green : .secondary)
                    .frame(width: 50)
                }
                // Lateness and gate are different questions, so a gate no
                // longer suppresses the delay: gates get assigned right around
                // the time a knock-on prediction matters most.
                if flight.showsPrediction, phase == .upcoming {
                    IntelligenceBadge(text: "Arc +\(flight.predictedDelayMinutes)m")
                } else if flight.delayMinutes > 0, !flight.isDisrupted {
                    Text("+\(flight.delayMinutes)m")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.orange)
                } else if !flight.isDisrupted, let qualifier = flight.dataTier.qualifier,
                          phase == .upcoming {
                    // This row has no status line, so without naming the source
                    // a timetable-only leg is indistinguishable from a tracked
                    // one — it just silently never shows a delay.
                    Text(qualifier)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                // A departure point is only news before departure.
                if let gate = flight.departureGate, phase == .upcoming, !flight.isDisrupted {
                    Text("\(flight.mode.boardingPointLabel) \(gate)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(!flight.reportsPunctuality ? .secondary
                                         : flight.showsPrediction || flight.delayMinutes > 0
                                             ? .orange : .green)
                }
            }
        }
    }

    private func countdownColor(_ flight: WidgetFlight, phase: WidgetFlight.Phase) -> Color {
        if flight.isDisrupted { return .red }
        if phase != .upcoming { return flight.reportsPunctuality ? .green : .secondary }
        return flight.reportsPunctuality && (flight.showsPrediction || flight.delayMinutes > 0)
            ? .orange : .primary
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
                } else {
                    NextFlightWidgetEntryView(entry: entry)
                        .padding()
                        .background()
                }
            }
        }
        .configurationDisplayName("Next Flight")
        .description("Countdown to your next flight with gate and status.")
        .supportedFamilies([.systemSmall, .systemMedium])
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
