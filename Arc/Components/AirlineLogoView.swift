import SwiftUI

/// Airline logo. Prefers a bundled asset, then a real logo from the CDN
/// (keyed by IATA), and falls back to a brand-color initials chip. The CDN
/// logo sits on a white tile so it reads in both light and dark mode.
struct AirlineLogoView: View {
    let iata: String
    var size: CGFloat = 28

    private var cdnURL: URL? {
        let code = iata.uppercased()
        guard code.count == 2 else { return nil }
        let px = Int(size * 3)   // retina
        return URL(string: "https://pics.avs.io/\(px)/\(px)/\(code).png")
    }

    var body: some View {
        if let asset = AirlineBranding.logoAssetName(iata: iata) {
            Image(asset).resizable().scaledToFit().frame(width: size, height: size)
        } else if let url = cdnURL {
            AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.15))) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                        .padding(size * 0.14)
                        .frame(width: size, height: size)
                        .background(.white, in: RoundedRectangle(cornerRadius: size * 0.22))
                default:
                    fallbackChip
                }
            }
            .frame(width: size, height: size)
        } else {
            fallbackChip
        }
    }

    private var fallbackChip: some View {
        RoundedRectangle(cornerRadius: size * 0.22)
            .fill(AirlineBranding.tailColor(iata: iata))
            .frame(width: size, height: size)
            .overlay(
                Text(AirlineBranding.initials(iata: iata))
                    .font(.system(size: size * 0.4, weight: .heavy))
                    .foregroundStyle(.white)
            )
    }
}
