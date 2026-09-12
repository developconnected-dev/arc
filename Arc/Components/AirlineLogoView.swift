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

    private var cache: LogoCache { .shared }

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
            // The cache answers synchronously, so a mark that has been drawn
            // once anywhere — the list row — is painted by its next copy
            // (the gliding card, the detail header) on its first frame,
            // instead of flashing the chip while a second fetch runs.
            switch cache[iconURL] {
            case .image(let image):
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            case .missing:
                wordmark
            case nil:
                fallbackChip.task(id: iconURL) { await cache.load(iconURL) }
            }
        } else {
            fallbackChip
        }
    }

    /// The CDN's wordmark sits on a white tile so it reads in both light
    /// and dark mode; a carrier the CDN does not know at all gets the chip.
    @ViewBuilder private var wordmark: some View {
        if let wordmarkURL, case .image(let image) = cache[wordmarkURL] {
            Image(uiImage: image).resizable().scaledToFit()
                .padding(size * 0.14)
                .frame(width: size, height: size)
                .background(.white, in: RoundedRectangle(cornerRadius: size * 0.22))
        } else if let wordmarkURL, cache[wordmarkURL] == nil {
            fallbackChip.task(id: wordmarkURL) { await cache.load(wordmarkURL) }
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

/// Logos fetched this launch, answered synchronously by URL.
///
/// `AsyncImage` starts every instance from its placeholder and fetches on
/// its own, so the three copies of one row that a tap creates (cell, glide,
/// header) each flashed the initials chip before the same PNG arrived
/// again. One shared table, observed by every logo view, means the fetch
/// happens once per URL per launch; the request itself prefers the disk
/// cache, so a second launch paints without the network at all.
@Observable @MainActor
final class LogoCache {
    static let shared = LogoCache()

    enum Entry: Equatable {
        case image(UIImage)
        /// The CDN answered without a usable image (404 for a carrier it has
        /// no icon for); remembered so the fallback is chosen once, not
        /// re-tried on every appearance.
        case missing
    }

    private var entries: [URL: Entry] = [:]
    @ObservationIgnored private var inflight: [URL: Task<Void, Never>] = [:]

    subscript(url: URL) -> Entry? { entries[url] }

    func load(_ url: URL) async {
        if entries[url] != nil { return }
        if let task = inflight[url] { await task.value; return }
        let task = Task { [weak self] in
            let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
            let fetched: Entry
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
               let image = UIImage(data: data) {
                fetched = .image(image)
            } else {
                fetched = .missing
            }
            self?.entries[url] = fetched
            self?.inflight[url] = nil
        }
        inflight[url] = task
        await task.value
    }
}
