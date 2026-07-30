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
            } else {
                // A conditional that renders nothing is never installed, and a
                // task on an uninstalled view never fires — so the card could
                // never load the data that would make it appear. This zero-size
                // anchor keeps the view installed until there is something to
                // show.
                Color.clear.frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        // Keyed on the prediction too: InboundMonitor re-checks every 15
        // minutes, and a knock-on that appears mid-view should surface
        // without leaving the screen.
        .task(id: "\(flight.id)-\(flight.predictedDelayMinutes)") { await load() }
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
        let inboundDriven = entry.assessment.reasons.first?.hasPrefix("Inbound aircraft") == true
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: high ? "exclamationmark.triangle.fill"
                  : inboundDriven ? "airplane.arrival" : "cloud.rain.fill")
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
    ///
    /// The departure entry is the full outlook, not just weather: it folds in
    /// the inbound aircraft's knock-on (computed by InboundMonitor) and, while
    /// that aircraft is still on the ground elsewhere, the weather where it's
    /// sitting — a thunderstorm over the feeder airport reaches this flight
    /// long before the airline says so.
    private func load() async {
        let refs = ReferenceData.shared
        var depWeather: DelayRisk.Assessment?
        if let icao = refs.airport(flight.departureIATA)?.icao, !icao.isEmpty,
           let conditions = try? await FlightAPIClient.shared
            .airportConditions(icao: icao, at: flight.effectiveDeparture) {
            depWeather = DelayRisk.assess(now: conditions.now, atDeparture: conditions.atTime)
        }

        // Origin weather only matters while the inbound hasn't left yet —
        // once it's airborne toward us, conditions back there are history.
        var originAssessment: DelayRisk.Assessment?
        let inbound = flight.rotationLegs.last
        if let inbound, inbound.status.lowercased() == "scheduled",
           let icao = refs.airport(inbound.depIATA)?.icao, !icao.isEmpty,
           let conditions = try? await FlightAPIClient.shared
            .airportConditions(icao: icao, at: .now) {
            originAssessment = DelayRisk.assess(now: conditions.now, atDeparture: conditions.atTime)
        }

        departure = DelayRisk.departureOutlook(
            weather: depWeather,
            knockOnMinutes: flight.predictedDelayMinutes,
            inboundOrigin: originAssessment,
            inboundOriginIATA: inbound?.depIATA)

        if let icao = refs.airport(flight.arrivalIATA)?.icao, !icao.isEmpty,
           let conditions = try? await FlightAPIClient.shared
            .airportConditions(icao: icao, at: flight.effectiveArrival) {
            arrival = DelayRisk.assess(now: conditions.now, atDeparture: conditions.atTime)
        }
    }
}
