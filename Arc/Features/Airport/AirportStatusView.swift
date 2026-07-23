import SwiftUI

/// Airport Intelligence sheet — live disruption status for one airport,
/// synthesized server-side from METAR aviation weather, FAA NAS status (US),
/// and Waitport security queues. Opened from the airport rows in Flight Detail.
struct AirportStatusView: View {
    let iata: String
    @Environment(\.dismiss) private var dismiss

    @State private var status: FlightAPIClient.AirportStatus?
    @State private var failed = false

    private var airport: AirportRef? { ReferenceData.shared.airport(iata) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if let status {
                        severityBanner(status)
                        if let reasons = status.reasons, !reasons.isEmpty {
                            reasonsCard(reasons)
                        }
                        if let w = status.weather { weatherCard(w) }
                        if let faa = status.faa { faaCard(faa) }
                        if let wait = status.securityMinutes {
                            infoRow(icon: "figure.walk.motion", title: "Security wait",
                                    value: "~\(wait) min", tint: wait > 20 ? .orange : .green)
                        }
                    } else if failed {
                        ContentUnavailableView("Status unavailable",
                                               systemImage: "wifi.slash",
                                               description: Text("Couldn't reach the airport data service."))
                            .padding(.top, 40)
                    } else {
                        HStack {
                            Spacer()
                            ProgressView("Checking \(iata)…").padding(.top, 60)
                            Spacer()
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("Airport Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            status = try await FlightAPIClient.shared.airportStatus(
                iata: iata, icao: airport?.icao, country: airport?.country)
            if status == nil { failed = true }
        } catch {
            failed = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(iata).font(.system(size: 34, weight: .heavy))
            Text(airport?.name ?? "").font(.system(size: 15)).foregroundStyle(.secondary)
        }
    }

    private func severityBanner(_ s: FlightAPIClient.AirportStatus) -> some View {
        let (color, icon): (Color, String) = switch s.severity {
        case "normal": (ArcTheme.onTime, "checkmark.seal.fill")
        case "minor": (.orange, "exclamationmark.circle.fill")
        case "major": (ArcTheme.late, "exclamationmark.triangle.fill")
        default: (Color(.secondaryLabel), "questionmark.circle")
        }
        return HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 20))
            Text(s.headline).font(.system(size: 18, weight: .bold))
            Spacer()
        }
        .foregroundStyle(color)
        .padding(14)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }

    private func reasonsCard(_ reasons: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(reasons, id: \.self) { r in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle.fill").font(.system(size: 5))
                        .foregroundStyle(.secondary).padding(.top, 6)
                    Text(r).font(.system(size: 14))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func weatherCard(_ w: FlightAPIClient.AirportStatus.Weather) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Weather now").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                if let t = w.tempC {
                    weatherStat(icon: "thermometer.medium", value: "\(Int(t.rounded()))°C")
                }
                if let wind = w.windKt {
                    weatherStat(icon: "wind",
                                value: "\(Int(wind)) kt" + (w.gustKt.map { " (G\(Int($0)))" } ?? ""))
                }
                if let vis = w.visibility {
                    weatherStat(icon: "eye", value: "\(vis) mi")
                }
                if let cat = w.category {
                    weatherStat(icon: "airplane", value: cat)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func weatherStat(icon: String, value: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .semibold))
        }
    }

    private func faaCard(_ faa: FlightAPIClient.AirportStatus.FaaDelay) -> some View {
        infoRow(icon: "exclamationmark.triangle.fill",
                title: faa.type,
                value: faa.reason + (faa.avgMinutes.map { " · avg \($0) min" } ?? ""),
                tint: ArcTheme.late)
    }

    private func infoRow(icon: String, title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(value).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
