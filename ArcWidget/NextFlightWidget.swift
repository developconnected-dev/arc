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
        let next = flights.first { $0.isUpcoming || $0.isActive }

        // Widget views are rendered ONCE per entry, at timeline-build time —
        // anything computed from Date.now in the view is frozen into that
        // render. Live movement comes from two places instead: auto-updating
        // date text/progress styles (system-animated, no process needed), and
        // extra entries at the moments the *layout* itself changes phase
        // (departure → in-flight look, arrival → landed look), so those flips
        // happen on time even if iOS never grants us a data refresh.
        var entries = [NextFlightEntry(date: .now, flight: next)]
        if let f = next {
            for moment in [f.effectiveDeparture, f.effectiveArrival] where moment > .now {
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
            VStack(alignment: .leading, spacing: 6) {
                // Countdown — .relative style is system-animated: it keeps
                // ticking on the lock/home screen with no app process running,
                // unlike the old pre-rendered countdownText string.
                Group {
                    if flight.isActive {
                        Text(flight.effectiveArrival, style: .relative)
                    } else {
                        Text(flight.effectiveDeparture, style: .relative)
                    }
                }
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(countdownColor(flight))
                .lineLimit(1)
                .minimumScaleFactor(0.6)

                // Route
                HStack(spacing: 4) {
                    Text(flight.departureIATA)
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(flight.arrivalIATA)
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                }

                // Flight number
                Text(flight.flightNumber)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                // Status
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor(flight))
                        .frame(width: 6, height: 6)
                    Text(statusText(flight))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                // Gate
                if let gate = flight.departureGate {
                    Text("Gate \(gate)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(statusColor(flight))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private func countdownColor(_ flight: WidgetFlight) -> Color {
        if flight.isActive { return .green }
        if flight.delayMinutes > 0 { return .orange }
        let hours = flight.timeUntilDeparture / 3600
        if hours < 2 { return .orange }
        return .primary
    }

    private func statusColor(_ flight: WidgetFlight) -> Color {
        if flight.status == "active" { return .green }
        if flight.delayMinutes > 0 { return .orange }
        if flight.status == "cancelled" { return .red }
        return .green
    }

    private func statusText(_ flight: WidgetFlight) -> String {
        if flight.isActive { return "In Flight" }
        if flight.delayMinutes > 0 { return "Delayed \(flight.delayMinutes)m" }
        if flight.status == "cancelled" { return "Cancelled" }
        return "On Time"
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
                    flightRow(flight)
                }
                if flights.count < 3 { Spacer() }
            }
        }
    }

    private func flightRow(_ flight: WidgetFlight) -> some View {
        HStack(spacing: 10) {
            // Countdown — live .relative style, not a pre-rendered string
            Group {
                if flight.isActive {
                    Text(flight.effectiveArrival, style: .relative)
                } else {
                    Text(flight.effectiveDeparture, style: .relative)
                }
            }
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .foregroundStyle(flight.isActive ? Color.green :
                                flight.delayMinutes > 0 ? .orange : .primary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: 62, alignment: .leading)

            // Route
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(flight.departureIATA)
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(flight.arrivalIATA)
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                }
                Text(flight.flightNumber)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Status + gate
            VStack(alignment: .trailing, spacing: 1) {
                if flight.isActive {
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
                        .foregroundStyle(flight.delayMinutes > 0 ? .orange : .green)
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
