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
                    switch phase {
                    // .relative is minute-precision (no seconds column) and
                    // the one live style every render path supports. The
                    // landed timeline entry retires the in-flight countdown
                    // before it could start counting up past the ETA.
                    case .inFlight: Text(flight.effectiveArrival, style: .relative)
                    case .upcoming: Text(flight.effectiveDeparture, style: .relative)
                    case .landed: Text(flight.status == "landed" ? "Landed" : "Arriving")
                    }
                }
                .font(.system(size: 22, weight: .heavy).monospacedDigit())
                .foregroundStyle(countdownColor(flight, phase: phase))
                .lineLimit(1)
                .minimumScaleFactor(0.6)

                // Route
                HStack(spacing: 4) {
                    Text(flight.departureIATA)
                        .font(.system(size: 15, weight: .heavy))
                    Image(systemName: phase == .landed ? "checkmark" : "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(phase == .landed ? .green : .secondary)
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
                    .tint(.green)
                }

                Spacer()

                // Status
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor(flight, phase: phase))
                        .frame(width: 6, height: 6)
                    Text(flight.statusText(phase: phase))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                // Gate
                if let gate = flight.departureGate, phase == .upcoming {
                    Text("Gate \(gate)")
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
                Text("No flights")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func countdownColor(_ flight: WidgetFlight, phase: WidgetFlight.Phase) -> Color {
        if phase != .upcoming { return .green }
        if flight.showsPrediction || flight.delayMinutes > 0 { return .orange }
        let hours = flight.timeUntilDeparture / 3600
        if hours < 2 { return .orange }
        return .primary
    }

    private func statusColor(_ flight: WidgetFlight, phase: WidgetFlight.Phase) -> Color {
        if phase != .upcoming { return .green }
        if flight.showsPrediction || flight.delayMinutes > 0 { return .orange }
        if flight.status == "cancelled" { return .red }
        return .green
    }
}

// MARK: - Medium Widget (Upcoming Flights)

struct NextFlightMediumView: View {
    let entry: NextFlightEntry
    private var flights: [WidgetFlight] {
        WidgetData.loadFlights().filter { $0.isUpcoming || $0.isActive }.prefix(3).map { $0 }
    }

    var body: some View {
        if flights.isEmpty {
            HStack {
                Image(systemName: "airplane")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No upcoming flights")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Add a flight in Arc")
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
                switch phase {
                case .inFlight: Text(flight.effectiveArrival, style: .relative)
                case .upcoming: Text(flight.effectiveDeparture, style: .relative)
                case .landed: Text(flight.status == "landed" ? "Landed" : "Arriving")
                }
            }
            .font(.system(size: 12, weight: .heavy).monospacedDigit())
            .foregroundStyle(phase != .upcoming ? Color.green :
                                (flight.showsPrediction || flight.delayMinutes > 0) ? .orange : .primary)
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
                    .tint(.green)
                    .frame(width: 50)
                }
                if let gate = flight.departureGate {
                    Text("Gate \(gate)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(flight.showsPrediction || flight.delayMinutes > 0 ? .orange : .green)
                } else if flight.showsPrediction {
                    Text("Arc +\(flight.predictedDelayMinutes)m")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.orange)
                } else if flight.delayMinutes > 0 {
                    Text("+\(flight.delayMinutes)m")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.orange)
                }
            }
        }
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
