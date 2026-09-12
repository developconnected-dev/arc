import SwiftUI

/// Airline logo. Prefers a bundled asset, then the carrier's square icon
/// from the CDN (keyed by IATA), then the CDN's wide wordmark on a white
/// tile, and finally a brand-colour initials chip.
///
/// The square icon is the same mark the airline paints on its tail or app
/// tile — Swiss's cross, Lufthansa's crane, easyJet's "e" — drawn edge to
/// edge on its own brand ground. At the 18–28pt this view is mostly shown,
/// that reads; a wordmark shrunk into the same square with a white margin
/// around it did not, which is why the wordmark is now only the fallback
/// for carriers the CDN has no icon for.
struct AirlineLogoView: View {
    let iata: String
    var size: CGFloat = 28

    private var code: String? {
        let code = iata.uppercased()
        return code.count == 2 ? code : nil
    }

    /// The tail/app-tile mark, full-bleed. `@2x` is the CDN's retina
    /// variant; the size is a hint it rounds to what it has.
    private var iconURL: URL? {
        guard let code else { return nil }
        let px = Int(size * 2)
        return URL(string: "https://pics.avs.io/al_square/\(px)/\(px)/\(code)@2x.png")
    }

    /// The wide wordmark, for carriers without a square icon.
    private var wordmarkURL: URL? {
        guard let code else { return nil }
        let px = Int(size * 3)
        return URL(string: "https://pics.avs.io/\(px)/\(px)/\(code).png")
    }

    var body: some View {
        if let asset = AirlineBranding.logoAssetName(iata: iata) {
            Image(asset).resizable().scaledToFit().frame(width: size, height: size)
        } else if let iconURL {
            AsyncImage(url: iconURL, transaction: Transaction(animation: .easeIn(duration: 0.15))) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
                case .failure:
                    wordmark
                default:
                    fallbackChip
                }
            }
            .frame(width: size, height: size)
        } else {
            fallbackChip
        }
    }

    /// The CDN's wordmark sits on a white tile so it reads in both light
    /// and dark mode; a carrier the CDN does not know at all gets the chip.
    private var wordmark: some View {
        AsyncImage(url: wordmarkURL, transaction: Transaction(animation: .easeIn(duration: 0.15))) { phase in
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
