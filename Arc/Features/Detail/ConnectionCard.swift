import SwiftUI

/// Connection Assistant card in Flight Detail: the other leg, the live
/// layover, a four-tier risk rating, and the concrete steps of the transfer
/// with typical times. Risk updates live as delays move either leg.
struct ConnectionCard: View {
    let plan: ConnectionPlanner.Plan
    let currentFlightID: UUID

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
