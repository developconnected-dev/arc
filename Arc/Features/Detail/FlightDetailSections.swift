import SwiftUI
import SwiftData

// MARK: - Shared

private func sectionTitle(_ text: String) -> some View {
    Text(text).font(.system(size: 22, weight: .bold))
        .frame(maxWidth: .infinity, alignment: .leading)
}

private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
}

// MARK: - Good to Know

struct GoodToKnowSection: View {
    let flight: Flight
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Good to Know")
            card { disruptionRow }
            if flight.timezoneDeltaHours != 0 {
                card {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.2.circlepath").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            let d = flight.timezoneDeltaHours
                            Text("\(d > 0 ? "+" : "")\(d) Hour Timezone Change")
                                .font(.system(size: 15, weight: .semibold))
                            Text("\(flight.arrTimeLocal) arrival is \(flight.arrivalInDepartureLocal) \(flight.departureCity) time")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var disruptionRow: some View {
        let (icon, tint, title, sub) = disruptionInfo
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(sub).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }

    private var disruptionInfo: (icon: String, tint: Color, title: String, sub: String) {
        if flight.status == .cancelled {
            return ("xmark.seal.fill", ArcTheme.late, "Flight cancelled",
                    "\(flight.departureIATA) → \(flight.arrivalIATA) will not operate as scheduled")
        }
        if flight.status == .diverted {
            return ("arrow.triangle.turn.up.right.diamond.fill", ArcTheme.late, "Flight diverted",
                    "This flight was routed to a different airport")
        }
        if flight.delayMinutes > 15 {
            return ("exclamationmark.triangle.fill", ArcTheme.late, "Running \(flight.delayMinutes)m late",
                    "\(flight.departureIATA) → \(flight.arrivalIATA) is experiencing delays")
        }
        if flight.delayMinutes > 0 {
            return ("clock.fill", .orange, "Minor delay — \(flight.delayMinutes)m",
                    "\(flight.departureIATA) and \(flight.arrivalIATA) operating with a short delay")
        }
        return ("checkmark.seal.fill", ArcTheme.onTime, "No known disruptions",
                "\(flight.departureIATA) and \(flight.arrivalIATA) operating normally")
    }
}

// MARK: - Where's My Plane

struct WheresMyPlaneSection: View {
    let flight: Flight
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Where's My Plane?").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                Text(flight.aircraftType ?? "Aircraft").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 16).padding(.top, 16)

            AircraftArt(type: flight.aircraftType, color: .white)
                .frame(maxWidth: .infinity).frame(height: 120)
                .padding(.horizontal, 24).padding(.vertical, 10)

            VStack(alignment: .leading, spacing: 10) {
                thisFlightRow
                if let inboundNumber = flight.inboundFlightNumber {
                    Divider().background(.white.opacity(0.2))
                    inboundLegRow(number: inboundNumber)
                } else if flight.inboundChecked && flight.aircraftRegistration != nil {
                    Divider().background(.white.opacity(0.2))
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle").foregroundStyle(.green)
                        Text("No delays on previous rotation")
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            .padding(16)
            .background(Color(.systemBackground).opacity(0.15))
        }
        .background(
            LinearGradient(colors: [Color(red: 0.28, green: 0.55, blue: 0.92),
                                    Color(red: 0.14, green: 0.38, blue: 0.75)],
                           startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var thisFlightRow: some View {
        HStack(spacing: 10) {
            Image(systemName: flight.isActive ? "airplane" : "arrow.down.circle")
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(flight.isActive ? "This flight — in the air" : "This Flight")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Text(statusText).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
            }
            Spacer()
            if let reg = flight.aircraftRegistration {
                Text(reg).font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    private func inboundLegRow(number: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.turn.down.right").foregroundStyle(.white.opacity(0.8))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(number).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    if let route = flight.inboundRoute {
                        Text(route).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                    }
                }
                HStack(spacing: 6) {
                    Text(inboundLegStatusText).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                    if let arrTime = flight.inboundArrivalTime {
                        Text("· \(arrTime.formatted(.dateTime.hour().minute()))")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            Spacer()
            // Status indicator
            if flight.inboundDelayMinutes > 15 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
            } else if flight.inboundDelayMinutes > 0 {
                Image(systemName: "clock.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.yellow)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.green)
            }
        }
    }

    private var statusText: String {
        if flight.isActive { return "Tracking live position" }
        if !flight.isUpcoming { return "This flight has already flown" }

        // No registration yet — airline hasn't assigned a tail
        if flight.aircraftRegistration == nil || flight.aircraftRegistration?.isEmpty == true {
            let hoursOut = flight.scheduledDeparture.timeIntervalSince(.now) / 3600
            if hoursOut > 24 {
                return "Aircraft typically assigned 1–24h before departure"
            }
            return "Aircraft not yet assigned by airline"
        }

        if !flight.inboundChecked { return "Checking previous rotation…" }
        if flight.inboundFlightNumber == nil { return "No prior rotation found for this tail" }
        if flight.inboundDelayMinutes > 0 { return "Inbound aircraft running \(flight.inboundDelayMinutes)m late" }
        return "Inbound aircraft on schedule"
    }

    private var inboundLegStatusText: String {
        if flight.inboundDelayMinutes > 15 { return "Landed \(flight.inboundDelayMinutes)m late" }
        if flight.inboundDelayMinutes > 0 { return "\(flight.inboundDelayMinutes)m late" }
        return "On time"
    }
}

// MARK: - Detailed Timetable

struct DetailedTimetableSection: View {
    let flight: Flight
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                sectionTitle("Detailed Timetable")
                Text("Scheduled, Estimated, and Actual")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            card {
                VStack(spacing: 14) {
                    groupHeader("DEPART")
                    timeRow("Gate Departure", scheduled: flight.depTimeLocal,
                            estimated: flight.departureChanged ? flight.effectiveDepTimeLocal : "--")
                    Divider()
                    groupHeader("ARRIVE")
                    timeRow("Gate Arrival", scheduled: flight.arrTimeLocal,
                            estimated: flight.arrivalChanged ? flight.effectiveArrTimeLocal : "--")
                    Divider()
                    groupHeader("TOTALS")
                    plainRow("Air Time", flight.durationFormatted)
                    plainRow("Distance", flight.distanceFormatted)
                }
            }
        }
    }

    private func groupHeader(_ t: String) -> some View {
        HStack {
            Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary).tracking(0.5)
            Spacer()
            Text("Scheduled").font(.system(size: 12)).foregroundStyle(.tertiary).frame(width: 80, alignment: .trailing)
            Text("Estimated").font(.system(size: 12)).foregroundStyle(.tertiary).frame(width: 80, alignment: .trailing)
        }
    }
    private func timeRow(_ label: String, scheduled: String, estimated: String) -> some View {
        HStack {
            Text(label).font(.system(size: 15, weight: .semibold))
            Spacer()
            Text(scheduled).font(.system(size: 15)).frame(width: 80, alignment: .trailing)
            Text(estimated).font(.system(size: 15)).foregroundStyle(estimated == "--" ? .secondary : .primary)
                .frame(width: 80, alignment: .trailing)
        }
    }
    private func plainRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 15, weight: .semibold))
            Spacer()
            Text(value).font(.system(size: 15)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Airline info

struct AirlineInfoSection: View {
    let flight: Flight
    private var airline: AirlineRef? { ReferenceData.shared.airline(flight.airlineCode) }
    var body: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    AirlineLogoView(iata: flight.airlineCode, size: 30)
                    Text(airline?.name ?? flight.airline).font(.system(size: 20, weight: .bold))
                }
                HStack {
                    infoCol("ATC Callsign", airline?.callsign ?? "—")
                    infoCol("ICAO", airline?.icao ?? flight.airlineICAO)
                    infoCol("IATA", flight.airlineCode)
                }
            }
        }
    }
    private func infoCol(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).font(.system(size: 15, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Route history

struct RouteHistorySection: View {
    let flight: Flight
    @Query private var all: [Flight]

    private var onRoute: [Flight] {
        all.filter { $0.status == .landed && $0.departureIATA == flight.departureIATA && $0.arrivalIATA == flight.arrivalIATA }
    }
    var body: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text("My History on This Route").font(.system(size: 18, weight: .bold))
                Text("\(flight.departureIATA) → \(flight.arrivalIATA)").font(.system(size: 13)).foregroundStyle(.secondary)
                HStack {
                    stat("Flights", "\(onRoute.count)")
                    stat("Distance", "\(Int(onRoute.map(\.distanceKm).reduce(0,+))) km")
                    stat("Flight Time", "\(Int(onRoute.map(\.duration).reduce(0,+)) / 3600)h")
                }
            }
        }
    }
    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Notes

struct NotesSection: View {
    let flight: Flight
    var onEdit: () -> Void
    var body: some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                Text("Notes").font(.system(size: 18, weight: .bold))
                Button(action: onEdit) {
                    Text(flight.notes.isEmpty ? "Tap to Edit" : flight.notes)
                        .font(.system(size: 15))
                        .foregroundStyle(flight.notes.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
