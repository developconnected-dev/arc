import SwiftUI

/// One piece of context above the first trip. Keep the existing status and
/// evidence model authoritative; this summary never invents a live update.
struct JourneyBrief {
    let title: String
    let message: String
    let symbol: String

    init(_ flight: Flight) {
        if flight.cancelUncertain {
            title = "Worth checking"
            message = "The provider flags a possible cancellation. Check with the operator."
            symbol = "exclamationmark.circle"
        } else if flight.isRecentlyLanded {
            title = "Arrival details"
            if flight.showsBaggageBelt, let belt = flight.baggageClaim, !belt.isEmpty {
                message = "Your baggage is assigned to belt \(belt)."
            } else {
                message = "Your journey and saved details are here when you need them."
            }
            symbol = "flag.checkered"
        } else if flight.isActive {
            title = flight.departurePhase.isHedged ? "Departure update" : "On your way"
            message = flight.departurePhase.isHedged
                ? "Departure is not yet confirmed. Open your trip for the latest details."
                : "Follow your route and see the latest arrival details."
            symbol = flight.mode.symbol
        } else if flight.dataTier == .manual {
            title = "Your plans, together"
            message = "Added by you. Open your trip to review the times and saved details."
            symbol = "bookmark"
        } else if flight.showsPrediction {
            title = "An early heads-up"
            message = "Arc predicts a \(FlightClock.delayText(flight.predictedDelayMinutes)) departure delay. This is an estimate, not an operator update."
            symbol = "sparkles"
        } else if flight.isUpcoming, flight.isSoon,
                  let gate = flight.departureGate, !gate.isEmpty {
            title = "Before you go"
            message = "\(flight.mode.boardingPointLabel) \(gate). Keep your trip handy for departure details."
            symbol = "arrow.up.right.circle"
        } else {
            title = "Next on your horizon"
            message = flight.dataTier == .scheduled
                ? "Based on the published timetable. Open your trip for the route and details."
                : "Your route, times and travel details, all together."
            symbol = "arrow.up.right"
        }
    }
}

struct JourneyBriefView: View {
    let flight: Flight

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            let brief = JourneyBrief(flight)
            VStack(alignment: .leading, spacing: 8) {
                Label(brief.title, systemImage: brief.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ArcTheme.brand)
                Text(brief.message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider().padding(.top, 4)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
