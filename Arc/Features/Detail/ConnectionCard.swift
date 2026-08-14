import SwiftUI
import SwiftData

/// Connection Assistant card in Flight Detail: the other leg, the live
/// layover, a four-tier risk rating, and the concrete steps of the transfer
/// with typical times. Risk updates live as delays move either leg.
struct ConnectionCard: View {
    let plan: ConnectionPlanner.Plan
    let currentFlightID: UUID
    var onSelectOther: ((Flight) -> Void)? = nil
    @Query private var allFlights: [Flight]

    /// The same plan re-run once the measurable parts have been measured —
    /// gate-to-gate distance, live security queue. Nil until that returns, so
    /// the card renders immediately from the heuristic plan and sharpens in
    /// place rather than making the user wait on the network for a layout.
    @State private var measured: ConnectionPlanner.Plan?
    private var shown: ConnectionPlanner.Plan { measured ?? plan }

    /// Median arrival lateness of the user's OWN completed flights on the
    /// inbound route — the leg whose lateness actually eats the layover.
    /// Personal history, so it only speaks with at least a little of it
    /// (2+ flights) and something worth saying (10m+ median).
    private var historyMedianDelay: Int? {
        let onRoute = allFlights.filter {
            $0.status == .landed
                && $0.departureIATA == shown.inbound.departureIATA
                && $0.arrivalIATA == shown.inbound.arrivalIATA
        }
        guard onRoute.count >= 2 else { return nil }
        let delays = onRoute.map(\.delayMinutes).sorted()
        let median = delays[delays.count / 2]
        return median >= 10 ? median : nil
    }

    private var otherLeg: Flight {
        shown.inbound.id == currentFlightID ? plan.outbound : plan.inbound
    }
    private var otherLegLabel: String {
        shown.inbound.id == currentFlightID ? "Onward flight" : "Arriving from"
    }

    private var riskColor: Color {
        switch shown.risk {
        case .relaxed: ArcTheme.onTime
        case .normal: ArcTheme.onTime
        case .tight: .orange
        case .risky: ArcTheme.late
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    onSelectOther?(otherLeg)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connection in \(shown.inbound.arrivalCity)")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.primary)
                        HStack(spacing: 4) {
                            Text("\(otherLegLabel): \(otherLeg.flightNumberSpaced) · \(otherLeg.departureIATA) → \(otherLeg.arrivalIATA)")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(onSelectOther == nil)
                Spacer()
                Text(shown.risk.rawValue)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(riskColor)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(riskColor.opacity(0.14), in: Capsule())
            }

            HStack(spacing: 14) {
                layoverStat(title: "LAYOVER", value: formatMinutes(shown.layoverMinutes),
                            color: riskColor)
                layoverStat(title: "YOU NEED ~", value: formatMinutes(shown.neededMinutes),
                            color: Color(.secondaryLabel))
                Spacer()
            }

            // Route memory: how this layover tends to play out for THIS user.
            // Plain styling on purpose — it's history, not Arc inference, so
            // it doesn't wear the smart mark.
            if let median = historyMedianDelay {
                let effective = shown.layoverMinutes - median
                let tighter = effective < shown.neededMinutes
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12))
                        .foregroundStyle(tighter ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    Text("Your \(shown.inbound.departureIATA) → \(shown.inbound.arrivalIATA) flights have arrived +\(median)m median — in practice this is more like a \(formatMinutes(max(0, effective))) layover.")
                        .font(.system(size: 13))
                        .foregroundStyle(tighter ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(shown.steps.enumerated()), id: \.offset) { _, step in
                    HStack(spacing: 10) {
                        Image(systemName: step.icon)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.name).font(.system(size: 14))
                            // Only present when the number was measured rather
                            // than assumed — so provenance shows up exactly
                            // where it's earned and nowhere else.
                            if let detail = step.detail {
                                Text(detail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Text("\(step.minutes) min")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Why a border step ISN'T here. Without it, a Schengen transfer
            // just silently lacks passport control and reads as an oversight
            // rather than as the answer.
            if let note = shown.borderNote {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 12))
                        .foregroundStyle(ArcTheme.onTime)
                    Text(note)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // The airport's own floor. Not Arc's estimate and not a guess about
            // this passenger — the shortest connection anybody will sell here,
            // which is a different and sometimes louder fact.
            if let minimum = shown.publishedMinimum {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: shown.isBelowPublishedMinimum
                          ? "exclamationmark.triangle.fill" : "checkmark.seal")
                        .font(.system(size: 12))
                        .foregroundStyle(shown.isBelowPublishedMinimum
                                         ? AnyShapeStyle(ArcTheme.late) : AnyShapeStyle(ArcTheme.onTime))
                    Text(shown.isBelowPublishedMinimum
                         ? "Shorter than \(shown.inbound.arrivalIATA)'s typical published minimum of \(minimum) min. On one ticket the airline owes you a rebooking; on two, a miss is at your own cost."
                         : "Clears \(shown.inbound.arrivalIATA)'s typical published minimum of \(minimum) min.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Says what it actually is. Once a step carries a measurement, the
            // blanket "typical times" disclaimer is no longer true, and
            // under-claiming is its own kind of dishonesty.
            Text(provenanceFootnote)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            if shown.risk == .tight || shown.risk == .risky {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(riskColor)
                    Text(shown.risk == .risky
                         ? "This connection is at risk — consider talking to the airline about alternatives."
                         : "Head straight to your next gate — little buffer left.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(riskColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        // Measure what can be measured, once, after the card is already on
        // screen. Every source is best-effort, so a failure here simply leaves
        // the heuristic plan showing rather than emptying the card.
        .task(id: plan.inbound.id) {
            let context = await ConnectionInsights.load(inbound: plan.inbound, outbound: plan.outbound)
            guard context != ConnectionPlanner.Context() else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                measured = ConnectionPlanner.plan(inbound: plan.inbound,
                                                  outbound: plan.outbound, context: context)
            }
        }
    }

    /// One line describing where these numbers came from — which changes once
    /// any of them stops being a heuristic.
    private var provenanceFootnote: String {
        let measuredSteps = shown.steps.filter { $0.detail != nil }.count
        guard measuredSteps > 0 else {
            return "Typical times for this airport — not live queue data."
        }
        return "\(measuredSteps) step\(measuredSteps == 1 ? "" : "s") measured from real gate and queue data; the rest are typical times."
    }

    private func layoverStat(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).tracking(0.4)
            Text(value).font(.system(size: 22, weight: .heavy).monospacedDigit()).foregroundStyle(color)
        }
    }

    private func formatMinutes(_ m: Int) -> String {
        let h = m / 60, r = m % 60
        return h > 0 ? "\(h)h \(r)m" : "\(r)m"
    }
}
