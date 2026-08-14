import SwiftUI
import CoreImage.CIFilterBuiltins
import UIKit

/// The share artifact: not a text blob — a boarding-pass-style ticket image
/// plus (when signed in) a link to the live cinematic tracking page the
/// Worker serves at /s/:code. Recipients need nothing but a browser; the
/// ticket carries a scannable QR of the same link.
struct ShareFlightSheet: View {
    let flight: Flight
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var supabase = ArcSupabase.shared

    @State private var liveURL: URL?
    @State private var linkState: LinkState = .working
    @State private var showActivity = false

    enum LinkState { case working, ready, unavailable }

    private static let shareBase = "https://arc-backend.owncalai.workers.dev/s/"

    var body: some View {
        ScrollView {
        VStack(spacing: 18) {
            Capsule().fill(Color(.systemGray4)).frame(width: 36, height: 5).padding(.top, 8)

            // EXACTLY the frame ImageRenderer rasterizes — what you see is
            // what gets shared. (An aspectRatio-only constraint let the
            // ticket adopt its ideal height and overflow the sheet.)
            ShareTicketView(flight: flight, sharerName: sharerName, liveURL: liveURL)
                .frame(width: 330, height: 330 / ShareTicketView.aspect)
                .fixedSize()
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)

            VStack(spacing: 6) {
                switch linkState {
                case .working:
                    Label("Creating live link…", systemImage: "clock")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                case .ready:
                    Label("Anyone with the link can watch this flight live for 48h — no app needed.",
                          systemImage: "dot.radiowaves.left.and.right")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                case .unavailable:
                    Label("Sign in on the Friends tab to add a live tracking link.",
                          systemImage: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 32)

            Button {
                showActivity = true
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(ArcTheme.action, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(linkState == .working)
            .padding(.horizontal, 28)

            Spacer(minLength: 8)
        }
        }
        .presentationDetents([.large])
        .task { await prepareLink() }
        .sheet(isPresented: $showActivity) {
            ActivityShareSheet(items: shareItems)
        }
    }

    private var sharerName: String {
        let name = supabase.currentUser?.display_name ?? ""
        return name.isEmpty ? "My flight" : "\(name) is flying"
    }

    /// Ticket image always; live URL when we have one, text fallback when not.
    private var shareItems: [Any] {
        var items: [Any] = []
        if let image = renderTicket() { items.append(image) }
        if let liveURL {
            items.append(liveURL)
        } else {
            items.append("\(flight.airline) \(flight.flightNumberSpaced) · \(flight.departureCity) → \(flight.arrivalCity) · \(flight.headerDateText), \(flight.depTimeLocal)")
        }
        return items
    }

    @MainActor private func renderTicket() -> UIImage? {
        let renderer = ImageRenderer(
            content: ShareTicketView(flight: flight, sharerName: sharerName, liveURL: liveURL)
                .frame(width: 330, height: 330 / ShareTicketView.aspect))
        renderer.scale = 3
        return renderer.uiImage
    }

    /// Signed in → make sure the flight is mirrored, then mint (or refresh)
    /// its 48-hour share code. Signed out → the ticket still shares fine.
    private func prepareLink() async {
        guard supabase.isSignedIn else { linkState = .unavailable; return }
        do {
            guard let rowId = try await supabase.shareFlight(flight) else {
                linkState = .unavailable; return
            }
            let code = try await supabase.journeyCode(forFlightId: rowId)
            liveURL = URL(string: Self.shareBase + code)
            linkState = .ready
        } catch {
            linkState = .unavailable
        }
    }
}

/// UIActivityViewController wrapper — the one-share path that hands iMessage
/// BOTH the ticket image and the live link (ShareLink can't mix item types).
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Ticket

/// The boarding-pass card. Pure SwiftUI so ImageRenderer can rasterize it at
/// 3× for sharing; the same view doubles as the on-screen preview.
struct ShareTicketView: View {
    let flight: Flight
    let sharerName: String
    let liveURL: URL?

    static let aspect: CGFloat = 360.0 / 470.0

    private let bg = Color(red: 0.024, green: 0.031, blue: 0.059)      // #06080F
    private let accent = Color(red: 0.435, green: 0.878, blue: 1.0)    // #6FE0FF
    private let dim = Color(red: 0.494, green: 0.545, blue: 0.639)

    var body: some View {
        VStack(spacing: 0) {
            main
            separator
            stub
        }
        .background(
            LinearGradient(colors: [bg, Color(red: 0.043, green: 0.071, blue: 0.133)],
                           startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24)
            .stroke(Color.white.opacity(0.10), lineWidth: 1))
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    TripLogoView(mode: flight.mode, iata: flight.airlineCode,
                                 logoURL: flight.operatorLogoURL, size: 24)
                    Text(flight.flightNumberSpaced)
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(.white)
                }
                Spacer()
                Text(flight.headerDateText.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(dim)
            }
            .padding(.bottom, 22)

            TicketArc(accent: accent)
                .frame(height: 64)
                .padding(.horizontal, 6)
                .padding(.bottom, 4)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(flight.departureIATA)
                        .font(.system(size: 40, weight: .heavy))
                        .foregroundStyle(.white)
                    Text(flight.departureCity)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(dim)
                    Text(flight.depTimeLocal)
                        .font(.system(size: 14, weight: .bold).monospacedDigit())
                        .foregroundStyle(accent)
                }
                Spacer()
                VStack(spacing: 3) {
                    Image(systemName: flight.mode.symbol)
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(accent)
                    Text(flight.durationFormatted)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(dim)
                }
                .padding(.top, 12)
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(flight.arrivalIATA)
                        .font(.system(size: 40, weight: .heavy))
                        .foregroundStyle(.white)
                    Text(flight.arrivalCity)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(dim)
                    Text(flight.arrTimeLocal)
                        .font(.system(size: 14, weight: .bold).monospacedDigit())
                        .foregroundStyle(accent)
                }
            }
        }
        .padding(22)
    }

    /// Notched boarding-pass separator.
    private var separator: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.black.opacity(0.85)).frame(width: 18, height: 18).offset(x: -9)
            ForEach(0..<24, id: \.self) { _ in
                Rectangle().fill(Color.white.opacity(0.14)).frame(height: 1.4)
            }
            Circle().fill(Color.black.opacity(0.85)).frame(width: 18, height: 18).offset(x: 9)
        }
        .frame(height: 18)
    }

    private var stub: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(sharerName.uppercased())
                    .font(.system(size: 11, weight: .heavy)).tracking(1.4)
                    .foregroundStyle(accent)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(liveURL != nil
                     ? "Scan to watch this flight live — no app needed."
                     : "Tracked with Arc.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(dim)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Image(systemName: "location.north.circle.fill").font(.system(size: 10))
                    Text("ARC · LIVE FOR 48H").font(.system(size: 9, weight: .heavy)).tracking(1.2)
                }
                .foregroundStyle(dim.opacity(0.8))
            }
            Spacer()
            if let liveURL, let qr = QRCode.image(for: liveURL.absoluteString) {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 74, height: 74)
                    .padding(6)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }
}

/// The glowing route arc on the ticket — same visual language as the map and
/// the share page: wide soft stroke under a crisp one, dotted overlay.
private struct TicketArcShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                       control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.35))
        return p
    }
}

private struct TicketArc: View {
    let accent: Color
    var body: some View {
        ZStack {
            TicketArcShape().stroke(accent.opacity(0.22), style: StrokeStyle(lineWidth: 7, lineCap: .round))
            TicketArcShape().stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            TicketArcShape().stroke(Color.white.opacity(0.9),
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.1, 8]))
        }
    }
}

enum QRCode {
    /// Crisp QR via CoreImage; rendered small then scaled with .interpolation(.none).
    static func image(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
