import SwiftUI

struct FlightCard: View {
    let flight: Flight

    private var countdown: String {
        if flight.isActive { return "NOW" }
        let interval = flight.scheduledDeparture.timeIntervalSince(.now)
        if interval <= 0 { return "NOW" }
        let days = Int(interval) / 86400
        let hours = (Int(interval) % 86400) / 3600
        if days > 0 { return "\(days)" }
        return "\(hours)h"
    }

    private var countdownLabel: String {
        let interval = flight.scheduledDeparture.timeIntervalSince(.now)
        if interval <= 0 || flight.isActive { return "" }
        let days = Int(interval) / 86400
        if days > 0 { return "DAYS" }
        return "HRS"
    }

    var body: some View {
        HStack(spacing: 14) {
            // Countdown badge
            VStack(spacing: 1) {
                Text(countdown)
                    .font(.system(size: countdown.count > 2 ? 20 : 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(flight.isActive ? .blue : .primary)
                if !countdownLabel.isEmpty {
                    Text(countdownLabel)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 50)

            // Flight info
            VStack(alignment: .leading, spacing: 4) {
                // Airline + flight number + date
                HStack {
                    Text(flight.flightNumber)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(flight.scheduledDeparture.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                // Route
                Text("\(flight.departureCity) to \(flight.arrivalCity)")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                // IATA codes + times
                HStack(spacing: 0) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.green)
                    Text(" \(flight.departureIATA) ")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(flight.scheduledDeparture.formatted(.dateTime.hour().minute()))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer().frame(width: 16)

                    Image(systemName: "arrow.down.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.blue)
                    Text(" \(flight.arrivalIATA) ")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(flight.scheduledArrival.formatted(.dateTime.hour().minute()))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                // Progress bar for active flights
                if flight.isActive {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.2)).frame(height: 3)
                            Capsule().fill(.blue)
                                .frame(width: geo.size.width * flight.progress, height: 3)
                        }
                    }
                    .frame(height: 3)
                    .padding(.top, 4)
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
    }
}

// MARK: - Status Pill

struct StatusPill: View {
    let status: FlightStatus
    let delay: Int

    private var label: String {
        switch status {
        case .scheduled: delay > 0 ? "Delayed \(delay)m" : "On Time"
        case .active: delay > 0 ? "In Air (Late \(delay)m)" : "In Air"
        case .landed: "Landed"
        case .cancelled: "Cancelled"
        case .diverted: "Diverted"
        }
    }

    private var color: Color {
        ArcColor.statusColor(for: status, delay: delay)
    }

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
    }
}
