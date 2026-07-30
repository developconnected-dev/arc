import SwiftUI

/// Weather that could actually hold this flight up, at the airport it departs
/// from and the one it arrives at.
///
/// Shows nothing at all unless the assessment clears the "moderate" bar — the
/// value here is that its silence means something. A card that appeared for
/// every shower would be ignored within a week.
struct DelayRiskCard: View {
    let flight: Flight

    @State private var departure: DelayRisk.Assessment?
    @State private var arrival: DelayRisk.Assessment?

    var body: some View {
        Group {
            if let worth = shown, !worth.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(worth, id: \.airport) { entry in
                        row(entry)
                    }
                }
                .padding(14)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .task(id: flight.id) { await load() }
    }

    private struct Entry {
        let airport: String
        let assessment: DelayRisk.Assessment
    }

    private var shown: [Entry]? {
        var out: [Entry] = []
        if let departure, departure.isWorthShowing {
            out.append(Entry(airport: flight.departureIATA, assessment: departure))
        }
        if let arrival, arrival.isWorthShowing {
            out.append(Entry(airport: flight.arrivalIATA, assessment: arrival))
        }
        return out
    }

    private func row(_ entry: Entry) -> some View {
        let high = entry.assessment.level == .high
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: high ? "exclamationmark.triangle.fill" : "cloud.rain.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(high ? ArcTheme.late : .orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.airport) · \(entry.assessment.level.title)")
                    .font(.system(size: 15, weight: .semibold))
                Text(entry.assessment.reasons.joined(separator: " · "))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// Departure is judged at departure time, arrival at arrival time — asking
    /// about the wrong end of the trip is how these features become noise.
    private func load() async {
        let refs = ReferenceData.shared
        if let icao = refs.airport(flight.departureIATA)?.icao, !icao.isEmpty,
           let conditions = try? await FlightAPIClient.shared
            .airportConditions(icao: icao, at: flight.effectiveDeparture) {
            departure = DelayRisk.assess(now: conditions.now, atDeparture: conditions.atTime)
        }
        if let icao = refs.airport(flight.arrivalIATA)?.icao, !icao.isEmpty,
           let conditions = try? await FlightAPIClient.shared
            .airportConditions(icao: icao, at: flight.effectiveArrival) {
            arrival = DelayRisk.assess(now: conditions.now, atDeparture: conditions.atTime)
        }
    }
}
