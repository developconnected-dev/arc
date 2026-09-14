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
    @State private var checkedAt: Date?

    var body: some View {
        Group {
            if flight.showsPrediction || shown?.isEmpty == false {
                VStack(alignment: .leading, spacing: 10) {
                    // The prediction's REASONING lives here, on the detail
                    // screen — the list chip states the number, this card
                    // explains it.
                    if flight.showsPrediction {
                        predictionSummary
                    }
                    ForEach(shown ?? [], id: \.airport) { entry in
                        row(entry)
                    }
                    // Date the assessment: "checked 2m ago" turns a quiet card
                    // into evidence that Arc is actually watching.
                    if let checkedAt {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            let mins = max(0, Int(context.date.timeIntervalSince(checkedAt) / 60))
                            Text(mins == 0 ? "Checked just now" : "Checked \(mins)m ago")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
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

    private var predictionSummary: some View {
        let comparison = DepartureComparison(flight)
        return VStack(alignment: .leading, spacing: 12) {
            SmartLabel(text: "An early heads-up", size: 15)
            Text(flight.predictionReason ?? "Delays on this aircraft’s earlier journeys may affect your departure.")
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) { comparisonTimes(comparison) }
                VStack(alignment: .leading, spacing: 12) { comparisonTimes(comparison) }
            }
            Text("Departure airport time. Arc’s estimate may change; follow the operator’s boarding instructions.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func comparisonTimes(_ comparison: DepartureComparison) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Arc estimate").font(.caption).foregroundStyle(.secondary)
            Text(comparison.predictedTime).font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(ArcTheme.brand)
        }
        VStack(alignment: .leading, spacing: 4) {
            Text(comparison.reportedLabel).font(.caption).foregroundStyle(.secondary)
            Text(comparison.reportedTime).font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
    }

    private struct Entry {
        let airport: String
        let assessment: DelayRisk.Assessment
    }

    private var shown: [Entry]? {
        var out: [Entry] = []
        if var departure, departure.isWorthShowing {
            // The prediction row above already explains the knock-on with
            // better reasoning — the outlook keeps only its OTHER reasons
            // (weather here, weather at the feeder), or stays silent.
            if flight.showsPrediction {
                let rest = departure.reasons.filter { !$0.hasPrefix("Inbound aircraft — about") }
                departure = DelayRisk.Assessment(level: departure.level, reasons: rest)
            }
            if !departure.reasons.isEmpty {
                out.append(Entry(airport: flight.departureIATA, assessment: departure))
            }
        }
        if let arrival, arrival.isWorthShowing {
            out.append(Entry(airport: flight.arrivalIATA, assessment: arrival))
        }
        return out
    }

    private func row(_ entry: Entry) -> some View {
        let high = entry.assessment.level == .high
        let inboundDriven = entry.assessment.reasons.first?.hasPrefix("Inbound aircraft") == true
        // Arc's own inference wears the smart mark; a HIGH warning keeps the
        // plain red triangle — urgency outranks branding.
        let smart = inboundDriven && !high
        return HStack(alignment: .top, spacing: 10) {
            Group {
                if high {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ArcTheme.late)
                } else if smart {
                    Image(systemName: "sparkles").foregroundStyle(ArcTheme.smartGradient)
                } else {
                    Image(systemName: "cloud.rain.fill").foregroundStyle(.orange)
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.airport) · \(entry.assessment.level.title)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(smart ? AnyShapeStyle(ArcTheme.smartGradient) : AnyShapeStyle(.primary))
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
        checkedAt = .now
    }
}

/// Compare the two sources against the same original schedule. Neither a
/// cached operator time nor an Arc estimate is presented as a confirmed event.
struct DepartureComparison {
    let predictedTime: String
    let reportedTime: String
    let reportedLabel: String

    init(_ flight: Flight) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = flight.depTimeZone
        formatter.dateFormat = "HH:mm"
        let predicted = flight.scheduledDeparture.addingTimeInterval(Double(flight.predictedDelayMinutes) * 60)
        let reported = flight.scheduledDeparture.addingTimeInterval(Double(flight.delayMinutes) * 60)
        let calendar = Calendar(identifier: .gregorian)
        var localCalendar = calendar
        localCalendar.timeZone = flight.depTimeZone
        let display = { (date: Date) -> String in
            let time = formatter.string(from: date)
            let days = localCalendar.dateComponents([.day],
                from: localCalendar.startOfDay(for: flight.scheduledDeparture),
                to: localCalendar.startOfDay(for: date)).day ?? 0
            return time + (days > 0 ? " (+\(days)d)" : "")
        }
        predictedTime = display(predicted)
        reportedTime = display(reported)
        reportedLabel = flight.dataTier == .manual ? "Saved departure"
            : flight.delayMinutes > 0 ? "Latest operator time" : "Published departure"
    }
}
