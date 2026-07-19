import SwiftUI
import UIKit

struct FlightDetailView: View {
    let flight: Flight
    @State private var shareURL: String?
    @State private var isSharing = false
    @ObservedObject private var supabase = ArcSupabase.shared

    var body: some View {
        ScrollView {
            VStack(spacing: ArcSpace.xl) {
                // Route header
                routeHeader

                // Status card
                statusCard

                // Gate & Terminal
                if flight.departureGate != nil || flight.departureTerminal != nil {
                    gateCard
                }

                // Aircraft info
                if let aircraft = flight.aircraftType {
                    aircraftCard(aircraft)
                }

                // Live position (in-flight radar)
                if flight.isActive, flight.liveLat != nil {
                    livePositionCard
                }

                // Share Journey
                if supabase.isSignedIn {
                    shareJourneyCard
                }

                // Inbound plane (Where's My Plane)
                if flight.isUpcoming || flight.isActive {
                    inboundCard
                }
            }
            .padding(.horizontal, ArcSpace.screen)
            .padding(.bottom, ArcSpace.xl)
        }
        .background(ArcColor.bg)
        .navigationTitle(flight.flightNumber)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Route Header

    private var routeHeader: some View {
        VStack(spacing: ArcSpace.l) {
            // Airport codes
            HStack {
                VStack(spacing: 4) {
                    Text(flight.departureIATA)
                        .font(.system(size: 36, weight: .heavy, design: .rounded))
                        .foregroundStyle(ArcColor.text)
                    Text(flight.departureCity)
                        .font(ArcType.caption)
                        .foregroundStyle(ArcColor.textMuted)
                }

                Spacer()

                VStack(spacing: 4) {
                    Image(systemName: "airplane")
                        .font(.system(size: 20))
                        .foregroundStyle(ArcColor.accent)
                        .rotationEffect(.degrees(90))
                    Text(flight.distanceFormatted)
                        .font(ArcType.caption)
                        .foregroundStyle(ArcColor.textDim)
                    Text(flight.durationFormatted)
                        .font(ArcType.captionEmph)
                        .foregroundStyle(ArcColor.textMuted)
                }

                Spacer()

                VStack(spacing: 4) {
                    Text(flight.arrivalIATA)
                        .font(.system(size: 36, weight: .heavy, design: .rounded))
                        .foregroundStyle(ArcColor.text)
                    Text(flight.arrivalCity)
                        .font(ArcType.caption)
                        .foregroundStyle(ArcColor.textMuted)
                }
            }
            .padding(.top, ArcSpace.l)

            // Progress bar for active flights
            if flight.isActive {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(ArcColor.border).frame(height: 4)
                        Capsule().fill(ArcColor.accent)
                            .frame(width: geo.size.width * flight.progress, height: 4)
                        // Plane dot
                        Circle().fill(ArcColor.accent)
                            .frame(width: 10, height: 10)
                            .offset(x: geo.size.width * flight.progress - 5)
                    }
                }
                .frame(height: 10)
            }

            StatusPill(status: flight.status, delay: flight.delayMinutes)
        }
    }

    // MARK: - Status Card

    private var statusCard: some View {
        VStack(spacing: ArcSpace.m) {
            detailRow(label: "Scheduled departure", value: flight.scheduledDeparture.formatted(.dateTime.hour().minute()))
            if let actual = flight.actualDeparture {
                detailRow(label: "Actual departure", value: actual.formatted(.dateTime.hour().minute()), highlight: flight.delayMinutes > 0)
            }
            Divider().background(ArcColor.border)
            detailRow(label: "Scheduled arrival", value: flight.scheduledArrival.formatted(.dateTime.hour().minute()))
            if let estimated = flight.estimatedArrival {
                detailRow(label: "Estimated arrival", value: estimated.formatted(.dateTime.hour().minute()), highlight: true)
            }
            Divider().background(ArcColor.border)
            detailRow(label: "Date", value: flight.scheduledDeparture.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
            detailRow(label: "Flight", value: "\(flight.airline) \(flight.flightNumber)")
        }
        .padding(ArcSpace.l)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ArcRadius.card))
    }

    // MARK: - Gate Card

    private var gateCard: some View {
        VStack(spacing: ArcSpace.m) {
            if let terminal = flight.departureTerminal {
                detailRow(label: "Departure terminal", value: terminal)
            }
            if let gate = flight.departureGate {
                detailRow(label: "Departure gate", value: gate)
            }
            if let terminal = flight.arrivalTerminal {
                detailRow(label: "Arrival terminal", value: terminal)
            }
            if let gate = flight.arrivalGate {
                detailRow(label: "Arrival gate", value: gate)
            }
            if let baggage = flight.baggageClaim {
                detailRow(label: "Baggage claim", value: baggage)
            }
        }
        .padding(ArcSpace.l)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ArcRadius.card))
    }

    // MARK: - Aircraft Card

    private func aircraftCard(_ type: String) -> some View {
        VStack(alignment: .leading, spacing: ArcSpace.m) {
            Text("Aircraft")
                .font(ArcType.captionEmph)
                .foregroundStyle(ArcColor.textMuted)
                .textCase(.uppercase)
                .tracking(0.8)

            HStack(spacing: ArcSpace.l) {
                Image(systemName: "airplane.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(ArcColor.accent)

                VStack(alignment: .leading, spacing: 4) {
                    Text(type)
                        .font(ArcType.bodyEmph)
                        .foregroundStyle(ArcColor.text)
                    if let reg = flight.aircraftRegistration {
                        Text(reg)
                            .font(ArcType.monoSmall)
                            .foregroundStyle(ArcColor.textMuted)
                    }
                }
            }
        }
        .padding(ArcSpace.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ArcRadius.card))
    }

    // MARK: - Inbound Card

    private var inboundCard: some View {
        VStack(alignment: .leading, spacing: ArcSpace.m) {
            HStack {
                Text("Where's My Plane?")
                    .font(ArcType.captionEmph)
                    .foregroundStyle(ArcColor.textMuted)
                    .textCase(.uppercase)
                    .tracking(0.8)
                Spacer()
                if flight.inboundDelayMinutes > 0 {
                    StatusPill(status: .scheduled, delay: flight.inboundDelayMinutes)
                }
            }

            if let inbound = flight.inboundFlightNumber {
                Text("Inbound: \(inbound)")
                    .font(ArcType.body)
                    .foregroundStyle(ArcColor.text)
                if flight.inboundDelayMinutes > 0 {
                    Text("Inbound plane is \(flight.inboundDelayMinutes) minutes late. This may affect your departure.")
                        .font(ArcType.caption)
                        .foregroundStyle(ArcColor.delayed)
                }
            } else {
                Text("Monitoring inbound aircraft...")
                    .font(ArcType.body)
                    .foregroundStyle(ArcColor.textMuted)
            }
        }
        .padding(ArcSpace.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ArcRadius.card))
    }

    // MARK: - Share Journey Card

    private var shareJourneyCard: some View {
        VStack(alignment: .leading, spacing: ArcSpace.m) {
            HStack {
                Text("Share Journey")
                    .font(ArcType.captionEmph)
                    .foregroundStyle(ArcColor.textMuted)
                    .textCase(.uppercase)
                    .tracking(0.8)
                Spacer()
            }

            if let url = shareURL {
                HStack {
                    Text(url)
                        .font(ArcType.monoSmall)
                        .foregroundStyle(ArcColor.accent)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = url
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(ArcColor.accent)
                    }
                    ShareLink(item: URL(string: url) ?? URL(string: "https://arc.flight")!) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(ArcColor.accent)
                    }
                }
            } else {
                Button {
                    Task { await createShareLink() }
                } label: {
                    HStack {
                        if isSharing {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "link.badge.plus")
                        }
                        Text(isSharing ? "Creating..." : "Create Live Link")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(ArcColor.accent)
                .controlSize(.large)
                .disabled(isSharing)
            }

            Text("Anyone with this link can see live flight status, gate, and position.")
                .font(ArcType.caption)
                .foregroundStyle(ArcColor.textDim)
        }
        .padding(ArcSpace.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ArcRadius.card))
    }

    private func createShareLink() async {
        isSharing = true
        do {
            let flightId = try await supabase.syncFlight(flight)
            let code = try await supabase.createSharedJourney(flightId: flightId)
            let endpoint = UserDefaults.standard.string(forKey: "apiEndpoint") ?? "https://arc-backend.workers.dev"
            shareURL = "\(endpoint)/journey/\(code)"
        } catch {}
        isSharing = false
    }

    // MARK: - Live Position Card

    private var livePositionCard: some View {
        VStack(alignment: .leading, spacing: ArcSpace.m) {
            Text("Live Position")
                .font(ArcType.captionEmph)
                .foregroundStyle(ArcColor.textMuted)
                .textCase(.uppercase)
                .tracking(0.8)

            HStack(spacing: ArcSpace.l) {
                Image(systemName: "location.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(ArcColor.accent)

                VStack(alignment: .leading, spacing: 6) {
                    if let alt = flight.liveAltitude {
                        HStack {
                            Text("Altitude")
                                .font(ArcType.caption)
                                .foregroundStyle(ArcColor.textMuted)
                            Spacer()
                            Text(String(format: "%.0f ft", alt * 3.281))
                                .font(ArcType.monoSmall)
                                .foregroundStyle(ArcColor.text)
                        }
                    }
                    if let speed = flight.liveSpeed {
                        HStack {
                            Text("Ground speed")
                                .font(ArcType.caption)
                                .foregroundStyle(ArcColor.textMuted)
                            Spacer()
                            Text(String(format: "%.0f kts", speed * 1.944))
                                .font(ArcType.monoSmall)
                                .foregroundStyle(ArcColor.text)
                        }
                    }
                    if let heading = flight.liveHeading {
                        HStack {
                            Text("Heading")
                                .font(ArcType.caption)
                                .foregroundStyle(ArcColor.textMuted)
                            Spacer()
                            Text(String(format: "%.0f°", heading))
                                .font(ArcType.monoSmall)
                                .foregroundStyle(ArcColor.text)
                        }
                    }
                    if let updated = flight.liveUpdatedAt {
                        HStack {
                            Text("Updated")
                                .font(ArcType.caption)
                                .foregroundStyle(ArcColor.textMuted)
                            Spacer()
                            Text(updated, style: .relative)
                                .font(ArcType.caption)
                                .foregroundStyle(ArcColor.textDim)
                        }
                    }
                }
            }
        }
        .padding(ArcSpace.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ArcRadius.card))
    }

    // MARK: - Helper

    private func detailRow(label: String, value: String, highlight: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(ArcType.body)
                .foregroundStyle(ArcColor.textMuted)
            Spacer()
            Text(value)
                .font(ArcType.bodyEmph)
                .foregroundStyle(highlight ? ArcColor.delayed : ArcColor.text)
        }
    }
}
