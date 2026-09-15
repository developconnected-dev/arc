import SwiftUI

/// One glass card per journey on the floating My Trips surface. The rows are
/// today's `FlightRowCard`s untouched; a connection's legs share the card,
/// joined by the live layover line where Soar draws a hairline.
struct JourneyCard: View {
    let journey: TripJourney
    /// The first journey carries the brief above its first leg.
    var showsBrief = false
    var onSelect: (Flight) -> Void
    var onDelete: (Flight) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsBrief, let first = journey.legs.first {
                JourneyBriefView(flight: first)
                    .padding(.horizontal, 14).padding(.top, 16)
            }
            ForEach(Array(journey.legs.enumerated()), id: \.element.id) { index, leg in
                if index > 0 {
                    LayoverConnector(plan: ConnectionPlanner.plan(inbound: journey.legs[index - 1], outbound: leg))
                }
                Button { onSelect(leg) } label: {
                    FlightRowCard(flight: leg)
                        .heroCopy(for: leg, side: .list)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("trip-row-\(leg.flightNumber)")
                // Swipe actions exist only in List, whose per-row cells would
                // split this card into strips of glass; a long press deletes.
                .contextMenu {
                    Button(role: .destructive) { onDelete(leg) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .glassEffect(ArcTheme.tripGlass, in: .rect(cornerRadius: ArcTheme.cardCorner))
    }
}

/// The live layover line between two connected legs: a spine through the
/// countdown column, a clock, and the planner's verdict, refreshed each
/// minute so "1h 12m layover" is never yesterday's number.
struct LayoverConnector: View {
    let plan: ConnectionPlanner.Plan

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            let layover = Int(plan.outbound.effectiveDeparture
                .timeIntervalSince(plan.inbound.effectiveArrival) / 60)
            let risk = ConnectionPlanner.risk(neededMinutes: plan.neededMinutes, layoverMinutes: layover)
            let tint: Color = switch risk {
            case .relaxed, .normal: ArcTheme.onTime
            case .tight: .orange
            case .risky: ArcTheme.late
            }
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(tint.opacity(0.45))
                    .frame(width: 2)
                    .frame(width: 52)   // centred under the countdown blocks
                Image(systemName: "clock")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text("\(FriendFlightMath.hmLower(layover)) layover in \(plan.inbound.arrivalIATA) • \(risk.rawValue)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
                Spacer()
            }
            .frame(height: 34)
            // FlightRowCard's inner padding, so the spine sits under the numbers.
            .padding(.horizontal, 14)
        }
    }
}
