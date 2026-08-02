import SwiftUI
import SwiftData

/// Connection Assistant card in Flight Detail: the other leg, the live
/// layover, a four-tier risk rating, and the concrete steps of the transfer
/// with typical times. Risk updates live as delays move either leg.
struct ConnectionCard: View {
    let plan: ConnectionPlanner.Plan
    let currentFlightID: UUID
    @Query private var allFlights: [Flight]

    /// Median arrival lateness of the user's OWN completed flights on the
    /// inbound route — the leg whose lateness actually eats the layover.
    /// Personal history, so it only speaks with at least a little of it
    /// (2+ flights) and something worth saying (10m+ median).
    private var historyMedianDelay: Int? {
        let onRoute = allFlights.filter {
            $0.status == .landed
                && $0.departureIATA == plan.inbound.departureIATA
                && $0.arrivalIATA == plan.inbound.arrivalIATA
        }
        guard onRoute.count >= 2 else { return nil }
        let delays = onRoute.map(\.delayMinutes).sorted()
        let median = delays[delays.count / 2]
        return median >= 10 ? median : nil
    }

    private var otherLeg: Flight {
        plan.inbound.id == currentFlightID ? plan.outbound : plan.inbound
    }
    private var otherLegLabel: String {
        plan.inbound.id == currentFlightID ? "Onward flight" : "Arriving from"
    }

    private var riskColor: Color {
        switch plan.risk {
        case .relaxed: ArcTheme.onTime
        case .normal: ArcTheme.onTime
        case .tight: .orange
        case .risky: ArcTheme.late
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connection in \(plan.inbound.arrivalCity)")
                        .font(.system(size: 17, weight: .bold))
                    Text("\(otherLegLabel): \(otherLeg.flightNumberSpaced) · \(otherLeg.departureIATA) → \(otherLeg.arrivalIATA)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(plan.risk.rawValue)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(riskColor)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(riskColor.opacity(0.14), in: Capsule())
            }

            HStack(spacing: 14) {
                layoverStat(title: "LAYOVER", value: formatMinutes(plan.layoverMinutes),
                            color: riskColor)
                layoverStat(title: "YOU NEED ~", value: formatMinutes(plan.neededMinutes),
                            color: Color(.secondaryLabel))
                Spacer()
            }

            // Route memory: how this layover tends to play out for THIS user.
            // Plain styling on purpose — it's history, not Arc inference, so
            // it doesn't wear the smart mark.
            if let median = historyMedianDelay {
                let effective = plan.layoverMinutes - median
                let tighter = effective < plan.neededMinutes
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12))
                        .foregroundStyle(tighter ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    Text("Your \(plan.inbound.departureIATA) → \(plan.inbound.arrivalIATA) flights have arrived +\(median)m median — in practice this is more like a \(formatMinutes(max(0, effective))) layover.")
                        .font(.system(size: 13))
                        .foregroundStyle(tighter ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in
                    HStack(spacing: 10) {
                        Image(systemName: step.icon)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text(step.name).font(.system(size: 14))
                        Spacer()
                        Text("\(step.minutes) min")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // These are tiered estimates (airport size, terminal change,
            // international vs domestic), not live airport data — say so.
            Text("Typical times for this airport — not live queue data.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            if plan.risk == .tight || plan.risk == .risky {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(riskColor)
                    Text(plan.risk == .risky
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
