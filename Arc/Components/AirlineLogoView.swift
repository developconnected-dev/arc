import SwiftUI

/// Renders a bundled airline logo if available, else a tail-color initials chip.
struct AirlineLogoView: View {
    let iata: String
    var size: CGFloat = 28

    var body: some View {
        if let asset = AirlineBranding.logoAssetName(iata: iata) {
            Image(asset).resizable().scaledToFit().frame(width: size, height: size)
        } else {
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
}
