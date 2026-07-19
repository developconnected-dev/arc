import ActivityKit
import WidgetKit
import SwiftUI

struct FlightLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FlightActivityAttributes.self) { context in
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.departureIATA)
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                        Text(context.state.departureTime, style: .time)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.attributes.arrivalIATA)
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                        // Auto-updating countdown to arrival — works offline
                        Text(context.state.arrivalTime, style: .relative)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(context.state.delayMinutes > 0 ? .orange : .white.opacity(0.6))
                    }
                }

                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 4) {
                        // Progress bar — computed from time, updates automatically
                        ProgressView(
                            timerInterval: context.state.departureTime...context.state.arrivalTime,
                            countsDown: false
                        )
                        .tint(statusAccent(context.state))
                        .scaleEffect(y: 0.5)

                        Text(context.attributes.flightNumber)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        statusLabel(context.state)
                        Spacer()
                        // Auto-updating "lands in X" — works offline
                        if context.state.status == "active" {
                            Text("Lands ")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                            + Text(context.state.arrivalTime, style: .relative)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.7))
                        } else if let gate = context.state.gate {
                            HStack(spacing: 4) {
                                Image(systemName: "door.left.hand.open")
                                    .font(.system(size: 10))
                                Text("Gate \(gate)")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    Image(systemName: "airplane")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(statusAccent(context.state))
                    Text(context.attributes.departureIATA)
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                }
            } compactTrailing: {
                // Auto-updating arrival countdown — works offline
                Text(context.state.arrivalTime, style: .timer)
                    .font(.system(size: 12, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 56)
                    .multilineTextAlignment(.trailing)
            } minimal: {
                Image(systemName: "airplane")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(statusAccent(context.state))
            }
        }
    }

    // MARK: - Lock Screen View

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<FlightActivityAttributes>) -> some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.departureIATA)
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    Text(context.state.departureTime, style: .time)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()

                // Time-based progress — auto-updates offline
                VStack(spacing: 6) {
                    ProgressView(
                        timerInterval: context.state.departureTime...context.state.arrivalTime,
                        countsDown: false
                    ) {
                        // Empty label
                    }
                    .tint(statusAccent(context.state))

                    Text(context.attributes.flightNumber)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .frame(maxWidth: 120)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(context.attributes.arrivalIATA)
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    // "Lands in 2h 34m" — auto-updates without internet
                    Text(context.state.arrivalTime, style: .relative)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(context.state.delayMinutes > 0 ? .orange : .white.opacity(0.6))
                }
            }

            HStack {
                statusLabel(context.state)
                Spacer()
                if let gate = context.state.gate {
                    HStack(spacing: 4) {
                        Image(systemName: "door.left.hand.open")
                            .font(.system(size: 10))
                        Text("Gate \(gate)")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .padding(16)
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
    }

    // MARK: - Helpers

    private func statusAccent(_ state: FlightActivityAttributes.ContentState) -> Color {
        switch state.status {
        case "active": state.delayMinutes > 15 ? .orange : Color.green
        case "landed": .green
        case "cancelled": .red
        case "diverted": .orange
        default: state.delayMinutes > 0 ? .orange : .green
        }
    }

    private func statusLabel(_ state: FlightActivityAttributes.ContentState) -> some View {
        let (text, color) = statusInfo(state)
        return Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(color)
    }

    private func statusInfo(_ state: FlightActivityAttributes.ContentState) -> (String, Color) {
        switch state.status {
        case "active":
            if state.delayMinutes > 0 {
                return ("Delayed \(state.delayMinutes)m", .orange)
            } else {
                return ("In Flight", Color.green)
            }
        case "landed":
            return ("Landed", .green)
        case "cancelled":
            return ("Cancelled", .red)
        case "diverted":
            return ("Diverted", .orange)
        default:
            if state.delayMinutes > 0 {
                return ("Delayed \(state.delayMinutes)m", .orange)
            } else {
                return ("On Time", .green)
            }
        }
    }
}
