import SwiftUI
import SwiftData

struct PassportStatsView: View {
    @Query(sort: \Flight.scheduledDeparture) private var allFlights: [Flight]

    private var completedFlights: [Flight] {
        allFlights.filter { $0.status == .landed }
    }

    private var totalDistance: Double {
        completedFlights.map(\.distanceKm).reduce(0, +)
    }

    private var totalDuration: TimeInterval {
        completedFlights.map(\.duration).reduce(0, +)
    }

    private var totalHours: Int { Int(totalDuration / 3600) }

    private var uniqueAirports: Set<String> {
        var airports = Set<String>()
        for f in completedFlights {
            airports.insert(f.departureIATA)
            airports.insert(f.arrivalIATA)
        }
        return airports
    }

    private var uniqueAirlines: Set<String> {
        Set(completedFlights.map(\.airline).filter { !$0.isEmpty })
    }

    private var uniqueCountries: Int {
        // Approximate: count unique first two letters of IATA as country proxy
        // Real implementation would use airport database
        Set(completedFlights.flatMap { [$0.departureIATA, $0.arrivalIATA] }
            .map { String($0.prefix(1)) }).count
    }

    private var totalDelayHours: Double {
        Double(completedFlights.map(\.delayMinutes).reduce(0, +)) / 60.0
    }

    private var worstDelay: Int {
        completedFlights.map(\.delayMinutes).max() ?? 0
    }

    private var flightYears: [Int] {
        let years = Set(completedFlights.map { Calendar.current.component(.year, from: $0.scheduledDeparture) })
        return years.sorted(by: >)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ArcSpace.xl) {
                    // Globe with all routes
                    GlobeView(flights: completedFlights)
                        .frame(height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: ArcRadius.card))

                    // Annual Review links
                    if !flightYears.isEmpty {
                        VStack(alignment: .leading, spacing: ArcSpace.m) {
                            Text("Year in Review")
                                .font(ArcType.captionEmph)
                                .foregroundStyle(ArcColor.textMuted)
                                .textCase(.uppercase)
                                .tracking(0.8)

                            ForEach(flightYears, id: \.self) { year in
                                let yearCount = completedFlights.filter {
                                    Calendar.current.component(.year, from: $0.scheduledDeparture) == year
                                }.count

                                NavigationLink {
                                    AnnualReviewView(year: year, flights: completedFlights)
                                } label: {
                                    HStack {
                                        Text("\(String(year))")
                                            .font(ArcType.heroSmall)
                                            .foregroundStyle(ArcColor.accent)
                                        Spacer()
                                        Text("\(yearCount) flights")
                                            .font(ArcType.caption)
                                            .foregroundStyle(ArcColor.textMuted)
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(ArcColor.textDim)
                                    }
                                    .padding(ArcSpace.l)
                                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ArcRadius.button))
                                }
                            }
                        }
                        .padding(ArcSpace.l)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ArcRadius.card))
                    }

                    // Stats grid
                    LazyVGrid(columns: [.init(), .init(), .init()], spacing: ArcSpace.m) {
                        statCell(value: "\(completedFlights.count)", label: "Flights", icon: "airplane")
                        statCell(value: formatDistance(totalDistance), label: "Distance", icon: "arrow.left.and.right")
                        statCell(value: "\(totalHours)h", label: "In the Air", icon: "clock.fill")
                        statCell(value: "\(uniqueAirports.count)", label: "Airports", icon: "building.2.fill")
                        statCell(value: "\(uniqueAirlines.count)", label: "Airlines", icon: "shield.fill")
                        statCell(value: "\(uniqueCountries)", label: "Regions", icon: "globe")
                    }

                    // Delay scoreboard
                    if totalDelayHours > 0 {
                        VStack(alignment: .leading, spacing: ArcSpace.m) {
                            Text("Delays")
                                .font(ArcType.captionEmph)
                                .foregroundStyle(ArcColor.textMuted)
                                .textCase(.uppercase)
                                .tracking(0.8)

                            HStack(spacing: ArcSpace.l) {
                                VStack(spacing: 4) {
                                    Text(String(format: "%.1fh", totalDelayHours))
                                        .font(ArcType.data)
                                        .foregroundStyle(ArcColor.delayed)
                                    Text("Total delayed")
                                        .font(ArcType.caption)
                                        .foregroundStyle(ArcColor.textMuted)
                                }
                                Spacer()
                                VStack(spacing: 4) {
                                    Text("\(worstDelay)m")
                                        .font(ArcType.data)
                                        .foregroundStyle(ArcColor.cancelled)
                                    Text("Worst delay")
                                        .font(ArcType.caption)
                                        .foregroundStyle(ArcColor.textMuted)
                                }
                            }
                        }
                        .padding(ArcSpace.l)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ArcRadius.card))
                    }

                    // Aircraft collection
                    let aircraftTypes = Dictionary(grouping: completedFlights.compactMap(\.aircraftType)) { $0 }
                        .sorted { $0.value.count > $1.value.count }

                    if !aircraftTypes.isEmpty {
                        VStack(alignment: .leading, spacing: ArcSpace.m) {
                            Text("Aircraft Collection")
                                .font(ArcType.captionEmph)
                                .foregroundStyle(ArcColor.textMuted)
                                .textCase(.uppercase)
                                .tracking(0.8)

                            ForEach(aircraftTypes.prefix(10), id: \.key) { type, flights in
                                HStack {
                                    Image(systemName: "airplane.circle.fill")
                                        .font(.system(size: 28))
                                        .foregroundStyle(ArcColor.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(type)
                                            .font(ArcType.bodyEmph)
                                            .foregroundStyle(ArcColor.text)
                                        Text("\(flights.count) flight\(flights.count == 1 ? "" : "s")")
                                            .font(ArcType.caption)
                                            .foregroundStyle(ArcColor.textMuted)
                                    }
                                    Spacer()
                                }
                            }
                        }
                        .padding(ArcSpace.l)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ArcRadius.card))
                    }

                    // Flight log
                    VStack(alignment: .leading, spacing: ArcSpace.m) {
                        Text("Flight Log")
                            .font(ArcType.captionEmph)
                            .foregroundStyle(ArcColor.textMuted)
                            .textCase(.uppercase)
                            .tracking(0.8)

                        ForEach(completedFlights.reversed().prefix(20)) { flight in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(flight.departureIATA) → \(flight.arrivalIATA)")
                                        .font(ArcType.monoSmall)
                                        .foregroundStyle(ArcColor.text)
                                    Text(flight.scheduledDeparture.formatted(.dateTime.month(.abbreviated).day().year()))
                                        .font(ArcType.caption)
                                        .foregroundStyle(ArcColor.textMuted)
                                }
                                Spacer()
                                Text(flight.airline)
                                    .font(ArcType.caption)
                                    .foregroundStyle(ArcColor.textDim)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(ArcSpace.l)
                    .background(ArcColor.card, in: RoundedRectangle(cornerRadius: ArcRadius.card))
                    .overlay(RoundedRectangle(cornerRadius: ArcRadius.card).strokeBorder(ArcColor.border))
                }
                .padding(.horizontal, ArcSpace.screen)
                .padding(.bottom, ArcSpace.xl)
            }
            .navigationTitle("Passport")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
    }

    // MARK: - Components

    private func statCell(value: String, label: String, icon: String) -> some View {
        VStack(spacing: ArcSpace.s) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(ArcColor.accent)
            Text(value)
                .font(ArcType.heroSmall)
                .foregroundStyle(ArcColor.text)
            Text(label)
                .font(ArcType.caption)
                .foregroundStyle(ArcColor.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ArcSpace.l)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ArcRadius.card))
    }

    private func formatDistance(_ km: Double) -> String {
        if km > 1_000_000 { return String(format: "%.1fM km", km / 1_000_000) }
        if km > 1000 { return String(format: "%.0fK km", km / 1000) }
        return String(format: "%.0f km", km)
    }
}
