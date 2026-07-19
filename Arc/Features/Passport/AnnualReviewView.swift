import SwiftUI
import SwiftData

struct AnnualReviewView: View {
    let year: Int
    let flights: [Flight]

    private var yearFlights: [Flight] {
        flights.filter {
            Calendar.current.component(.year, from: $0.scheduledDeparture) == year
        }
    }

    private var completedFlights: [Flight] {
        yearFlights.filter { $0.status == .landed }
    }

    private var totalDistance: Double {
        completedFlights.map(\.distanceKm).reduce(0, +)
    }

    private var totalHours: Int {
        Int(completedFlights.map(\.duration).reduce(0, +) / 3600)
    }

    private var uniqueAirports: Int {
        var airports = Set<String>()
        for f in completedFlights {
            airports.insert(f.departureIATA)
            airports.insert(f.arrivalIATA)
        }
        return airports.count
    }

    private var longestFlight: Flight? {
        completedFlights.max(by: { $0.distanceKm < $1.distanceKm })
    }

    private var shortestFlight: Flight? {
        completedFlights.min(by: { $0.distanceKm < $1.distanceKm })
    }

    private var busiestMonth: String? {
        let grouped = Dictionary(grouping: completedFlights) {
            Calendar.current.component(.month, from: $0.scheduledDeparture)
        }
        guard let (month, _) = grouped.max(by: { $0.value.count < $1.value.count }) else { return nil }
        let formatter = DateFormatter()
        formatter.monthSymbols = formatter.monthSymbols
        return formatter.monthSymbols[month - 1]
    }

    private var busiestMonthCount: Int {
        let grouped = Dictionary(grouping: completedFlights) {
            Calendar.current.component(.month, from: $0.scheduledDeparture)
        }
        return grouped.values.map(\.count).max() ?? 0
    }

    private var topAirlines: [(String, Int)] {
        Dictionary(grouping: completedFlights) { $0.airline }
            .filter { !$0.key.isEmpty }
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
    }

    private var topRoutes: [(String, Int)] {
        Dictionary(grouping: completedFlights) { "\($0.departureIATA)→\($0.arrivalIATA)" }
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
    }

    private var monthlyBreakdown: [(String, Int)] {
        let grouped = Dictionary(grouping: completedFlights) {
            Calendar.current.component(.month, from: $0.scheduledDeparture)
        }
        let formatter = DateFormatter()
        return (1...12).map { month in
            let short = formatter.shortMonthSymbols[month - 1]
            return (short, grouped[month]?.count ?? 0)
        }
    }

    private var totalDelayMinutes: Int {
        completedFlights.map(\.delayMinutes).reduce(0, +)
    }

    private var earthCircumferences: Double {
        totalDistance / 40_075
    }

    var body: some View {
        ScrollView {
            VStack(spacing: ArcSpace.xl) {
                // Hero
                VStack(spacing: ArcSpace.s) {
                    Text("\(String(year))")
                        .font(.system(size: 56, weight: .heavy, design: .rounded))
                        .foregroundStyle(ArcColor.accent)
                    Text("Year in Review")
                        .font(ArcType.title)
                        .foregroundStyle(ArcColor.textMuted)
                }
                .padding(.top, ArcSpace.xl)

                // Shared map with this year's routes (temporary; rebuilt in Passport plan)
                ArcMapView(flights: completedFlights, controller: MapController())
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: ArcRadius.card))

                // Big stats
                LazyVGrid(columns: [.init(), .init()], spacing: ArcSpace.m) {
                    bigStat(value: "\(completedFlights.count)", label: "Flights")
                    bigStat(value: formatDistance(totalDistance), label: "Distance")
                    bigStat(value: "\(totalHours)h", label: "In the Air")
                    bigStat(value: "\(uniqueAirports)", label: "Airports")
                }

                // Fun comparison
                if earthCircumferences > 0.1 {
                    comparisonCard
                }

                // Monthly chart
                monthlyChart

                // Records
                recordsCard

                // Top airlines
                if !topAirlines.isEmpty {
                    rankingCard(title: "Top Airlines", items: topAirlines.prefix(5).map { $0 })
                }

                // Top routes
                if !topRoutes.isEmpty {
                    rankingCard(title: "Most Flown Routes", items: topRoutes.prefix(5).map { $0 })
                }

                // Delay stats
                if totalDelayMinutes > 0 {
                    delayCard
                }
            }
            .padding(.horizontal, ArcSpace.screen)
            .padding(.bottom, ArcSpace.xl)
        }
        .background(ArcColor.bg)
        .navigationTitle("\(String(year)) Review")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Components

    private func bigStat(value: String, label: String) -> some View {
        VStack(spacing: ArcSpace.s) {
            Text(value)
                .font(.system(size: 32, weight: .heavy, design: .rounded))
                .foregroundStyle(ArcColor.text)
            Text(label)
                .font(ArcType.captionEmph)
                .foregroundStyle(ArcColor.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ArcSpace.xl)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ArcRadius.card))
    }

    private var comparisonCard: some View {
        VStack(spacing: ArcSpace.m) {
            Image(systemName: "globe.americas.fill")
                .font(.system(size: 32))
                .foregroundStyle(ArcColor.accent)
            Text(String(format: "%.1f× around Earth", earthCircumferences))
                .font(ArcType.heroSmall)
                .foregroundStyle(ArcColor.text)
            Text(String(format: "%.0f km flown this year", totalDistance))
                .font(ArcType.caption)
                .foregroundStyle(ArcColor.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(ArcSpace.xl)
        .background(ArcColor.card, in: RoundedRectangle(cornerRadius: ArcRadius.card))
        .glassEffect(.regular.tint(ArcColor.accent), in: RoundedRectangle(cornerRadius: ArcRadius.card))
    }

    private var monthlyChart: some View {
        VStack(alignment: .leading, spacing: ArcSpace.m) {
            Text("Monthly Flights")
                .font(ArcType.captionEmph)
                .foregroundStyle(ArcColor.textMuted)
                .textCase(.uppercase)
                .tracking(0.8)

            let maxCount = monthlyBreakdown.map(\.1).max() ?? 1

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(monthlyBreakdown, id: \.0) { month, count in
                    VStack(spacing: 4) {
                        if count > 0 {
                            Text("\(count)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(ArcColor.textMuted)
                        }

                        RoundedRectangle(cornerRadius: 3)
                            .fill(count > 0 ? ArcColor.accent : ArcColor.border)
                            .frame(height: max(4, CGFloat(count) / CGFloat(maxCount) * 80))

                        Text(month)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(ArcColor.textDim)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 110)
        }
        .padding(ArcSpace.l)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ArcRadius.card))
    }

    private var recordsCard: some View {
        VStack(alignment: .leading, spacing: ArcSpace.m) {
            Text("Records")
                .font(ArcType.captionEmph)
                .foregroundStyle(ArcColor.textMuted)
                .textCase(.uppercase)
                .tracking(0.8)

            if let longest = longestFlight {
                HStack {
                    Image(systemName: "arrow.up.right")
                        .foregroundStyle(ArcColor.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Longest flight")
                            .font(ArcType.caption)
                            .foregroundStyle(ArcColor.textMuted)
                        Text("\(longest.departureIATA) → \(longest.arrivalIATA)")
                            .font(ArcType.monoSmall)
                            .foregroundStyle(ArcColor.text)
                        Text(String(format: "%.0f km • %@", longest.distanceKm, longest.durationFormatted))
                            .font(ArcType.caption)
                            .foregroundStyle(ArcColor.textDim)
                    }
                    Spacer()
                }
            }

            if let shortest = shortestFlight, shortestFlight?.id != longestFlight?.id {
                HStack {
                    Image(systemName: "arrow.down.right")
                        .foregroundStyle(ArcColor.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Shortest flight")
                            .font(ArcType.caption)
                            .foregroundStyle(ArcColor.textMuted)
                        Text("\(shortest.departureIATA) → \(shortest.arrivalIATA)")
                            .font(ArcType.monoSmall)
                            .foregroundStyle(ArcColor.text)
                        Text(String(format: "%.0f km • %@", shortest.distanceKm, shortest.durationFormatted))
                            .font(ArcType.caption)
                            .foregroundStyle(ArcColor.textDim)
                    }
                    Spacer()
                }
            }

            if let busiest = busiestMonth {
                HStack {
                    Image(systemName: "calendar")
                        .foregroundStyle(ArcColor.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Busiest month")
                            .font(ArcType.caption)
                            .foregroundStyle(ArcColor.textMuted)
                        Text("\(busiest) — \(busiestMonthCount) flights")
                            .font(ArcType.bodyEmph)
                            .foregroundStyle(ArcColor.text)
                    }
                    Spacer()
                }
            }
        }
        .padding(ArcSpace.l)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ArcRadius.card))
    }

    private func rankingCard(title: String, items: [(String, Int)]) -> some View {
        VStack(alignment: .leading, spacing: ArcSpace.m) {
            Text(title)
                .font(ArcType.captionEmph)
                .foregroundStyle(ArcColor.textMuted)
                .textCase(.uppercase)
                .tracking(0.8)

            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                HStack {
                    Text("#\(idx + 1)")
                        .font(ArcType.monoSmall)
                        .foregroundStyle(ArcColor.accent)
                        .frame(width: 30, alignment: .leading)
                    Text(item.0)
                        .font(ArcType.bodyEmph)
                        .foregroundStyle(ArcColor.text)
                    Spacer()
                    Text("\(item.1) flight\(item.1 == 1 ? "" : "s")")
                        .font(ArcType.caption)
                        .foregroundStyle(ArcColor.textMuted)
                }
            }
        }
        .padding(ArcSpace.l)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ArcRadius.card))
    }

    private var delayCard: some View {
        VStack(alignment: .leading, spacing: ArcSpace.m) {
            Text("Delays")
                .font(ArcType.captionEmph)
                .foregroundStyle(ArcColor.textMuted)
                .textCase(.uppercase)
                .tracking(0.8)

            let delayedFlights = completedFlights.filter { $0.delayMinutes > 0 }
            let onTimePct = completedFlights.isEmpty ? 100 : 100 - Int(Double(delayedFlights.count) / Double(completedFlights.count) * 100)

            HStack {
                VStack(spacing: 4) {
                    Text("\(totalDelayMinutes)m")
                        .font(ArcType.data)
                        .foregroundStyle(ArcColor.delayed)
                    Text("Total delay")
                        .font(ArcType.caption)
                        .foregroundStyle(ArcColor.textMuted)
                }
                Spacer()
                VStack(spacing: 4) {
                    Text("\(delayedFlights.count)")
                        .font(ArcType.data)
                        .foregroundStyle(ArcColor.delayed)
                    Text("Delayed flights")
                        .font(ArcType.caption)
                        .foregroundStyle(ArcColor.textMuted)
                }
                Spacer()
                VStack(spacing: 4) {
                    Text("\(onTimePct)%")
                        .font(ArcType.data)
                        .foregroundStyle(onTimePct < 70 ? ArcColor.cancelled : ArcColor.onTime)
                    Text("On-time rate")
                        .font(ArcType.caption)
                        .foregroundStyle(ArcColor.textMuted)
                }
            }
        }
        .padding(ArcSpace.l)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ArcRadius.card))
    }

    // MARK: - Helpers

    private func formatDistance(_ km: Double) -> String {
        if km > 1_000_000 { return String(format: "%.1fM km", km / 1_000_000) }
        if km > 1000 { return String(format: "%.0fK km", km / 1000) }
        return String(format: "%.0f km", km)
    }
}
