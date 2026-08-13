import SwiftUI

/// The operator's mark for any leg — airline, ferry line or railway.
///
/// One view for all three so a trip list mixing them reads as one list rather
/// than three. Airlines keep the existing bundled-asset/CDN path; ferry
/// operators use the artwork Ferryhopper supplies per sailing; railways have no
/// logo source at all and fall back to a mode glyph.
///
/// Why not extend `AirlineLogoView`: it is keyed by IATA code and its fallback
/// is a brand-coloured initials chip. Off-air there is no IATA code, so that
/// fallback rendered a bare coloured square — a red block sitting where a Greek
/// ferry's identity should be. The distinction is real enough to deserve its
/// own view rather than more branches inside that one.
struct TripLogoView: View {
    let mode: TripMode
    /// Airline IATA, when this is a flight. Empty otherwise.
    var iata: String = ""
    /// Operator artwork supplied by the provider — ferries only, today.
    var logoURL: String?
    var size: CGFloat = 28

    var body: some View {
        if mode == .air {
            AirlineLogoView(iata: iata, size: size)
        } else if let url = logoURL.flatMap(URL.init(string:)) {
            AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.15))) { phase in
                switch phase {
                case .success(let image):
                    // Ferry marks are supplied as artwork on white, so the same
                    // white tile the airline CDN logos sit on keeps them legible
                    // in dark mode instead of vanishing into the sheet.
                    image.resizable().scaledToFit()
                        .padding(size * 0.12)
                        .frame(width: size, height: size)
                        .background(.white, in: RoundedRectangle(cornerRadius: size * 0.22))
                default:
                    // Covers loading, failure and offline alike: a glyph is a
                    // better placeholder than an empty box, and this view is
                    // used in a list that scrolls past before slow images land.
                    glyph
                }
            }
            .frame(width: size, height: size)
        } else {
            glyph
        }
    }

    private var glyph: some View {
        RoundedRectangle(cornerRadius: size * 0.22)
            .fill(Color(.secondarySystemBackground))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: mode.symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.secondary)
            )
    }
}
