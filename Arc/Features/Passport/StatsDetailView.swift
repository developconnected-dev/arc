import SwiftUI

enum StatsMode: String, Identifiable {
    case flight, delay, aircraft
    var id: String { rawValue }
    var title: String {
        switch self { case .flight: "Flight Stats"; case .delay: "Delay Stats"; case .aircraft: "Aircraft Stats" }
    }
}

/// Expanded breakdowns behind the Passport "All … Stats" buttons.
struct StatsDetailView: View {
    let flights: [Flight]      // scoped, landed
    let mode: StatsMode
    @Environment(\.dismiss) private var dismiss

    private var stats: PassportStats { PassportStats(flights) }

    var body: some View {
        NavigationStack {
            List {
                switch mode {
                case .flight: flightSection
                case .delay: delaySection
                case .aircraft: aircraftSection
                }
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    // MARK: Flight

    @ViewBuilder private var flightSection: some View {
        Section {
            row("Trips", "\(stats.flights)")
            row("Distance", stats.distanceFormatted)
            row("Around the world", String(format: "%.1f×", stats.distanceKm / 40075.0))
            row("Time in the air", stats.flightTimeFormatted)
            row("Airports", "\(stats.airports)")
            row("Airlines", "\(stats.airlines)")
            row("Countries", "\(countries)")
            row("Long-haul flights", "\(stats.longHaul)")
        }
        if let longest {
            Section("Longest flight") {
                row("\(longest.departureIATA) → \(longest.arrivalIATA)", "\(Int(longest.distanceKm)) km")
            }
        }
        if let (route, count) = topRoute {
            Section("Most flown route") { row(route, "\(count)×") }
        }
        if let (apt, count) = topAirport {
            Section("Most visited airport") { row(apt, "\(count) visits") }
        }
    }

    private var countries: Int {
        var set = Set<String>()
        for f in flights {
            if let c = ReferenceData.shared.airport(f.departureIATA)?.country { set.insert(c) }
            if let c = ReferenceData.shared.airport(f.arrivalIATA)?.country { set.insert(c) }
        }
        return set.count
    }
    private var longest: Flight? { flights.max { $0.distanceKm < $1.distanceKm } }
    private var topRoute: (String, Int)? {
        var counts: [String: Int] = [:]
        for f in flights {
            let key = [f.departureIATA, f.arrivalIATA].sorted().joined(separator: " ↔ ")
            counts[key, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }
    private var topAirport: (String, Int)? {
        var counts: [String: Int] = [:]
        for f in flights { counts[f.departureIATA, default: 0] += 1; counts[f.arrivalIATA, default: 0] += 1 }
        return counts.max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }

    // MARK: Delay

    @ViewBuilder private var delaySection: some View {
        Section {
            row("Minutes lost", "\(stats.delayMinutesLost)")
            row("Delayed trips", "\(stats.delayedFlights) of \(stats.flights)")
            row("Average delay", "\(stats.avgDelay)m")
            row("On-time rate", onTimeRate)
            row("Worst delay", "\(worstDelay)m")
        }
        if !delayByAirline.isEmpty {
            Section("Delay by airline") {
                ForEach(delayByAirline, id: \.0) { code, mins in
                    row(ReferenceData.shared.airline(code)?.name ?? code, "\(mins)m")
                }
            }
        }
    }

    private var onTimeRate: String {
        guard stats.flights > 0 else { return "—" }
        let onTime = flights.filter { $0.delayMinutes == 0 }.count
        return "\(Int(Double(onTime) / Double(stats.flights) * 100))%"
    }
    private var worstDelay: Int { flights.map(\.delayMinutes).max() ?? 0 }
    private var delayByAirline: [(String, Int)] {
        var counts: [String: Int] = [:]
        // Only legs whose source reported punctuality — and only airlines:
        // charging a rail operator's timetable slip to "delay by airline"
        // would be invented data twice over.
        for f in flights where f.delayMinutes > 0 && f.mode == .air && f.dataTier.reportsPunctuality {
            counts[f.airlineCode, default: 0] += f.delayMinutes
        }
        return counts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    // MARK: Aircraft

    @ViewBuilder private var aircraftSection: some View {
        if let most = stats.mostFlownAircraft {
            Section {
                HStack {
                    AircraftArt(type: most, color: .accentColor)
                        .frame(width: 90, height: 44)
                    VStack(alignment: .leading) {
                        Text(most).font(.system(size: 17, weight: .bold))
                        Text("\(stats.mostFlownCount) flights").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Most flown") }
        }
        Section("Aircraft collection") {
            ForEach(collection, id: \.0) { type, count in
                HStack {
                    AircraftArt(type: type, color: Color(.label))
                        .frame(width: 54, height: 26)
                    Text(type).font(.system(size: 15))
                    Spacer()
                    Text("\(count)×").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var collection: [(String, Int)] {
        Dictionary(grouping: flights.compactMap { $0.aircraftType }, by: { $0 })
            .mapValues(\.count).sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    // MARK: helper

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).foregroundStyle(.secondary).fontWeight(.semibold) }
    }
}
