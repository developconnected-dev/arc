import SwiftUI
import UIKit

/// Avatar for a person: their Memoji/photo when they've set one, otherwise
/// initials on a deterministic per-person color. Used everywhere an identity
/// shows — list rows, filter chips, map bubbles, settings.
struct FriendAvatar: View {
    let name: String
    var size: CGFloat = 36
    /// `avatar_url` from the profile row — a data: URL holding the image.
    var avatarURL: String? = nil

    var body: some View {
        if let avatarURL, let (emoji, color) = Self.parseEmojiAvatar(avatarURL) {
            ZStack {
                Circle().fill(color.gradient)
                Text(emoji).font(.system(size: size * 0.58))
            }
            .frame(width: size, height: size)
        } else if let avatarURL, let image = Self.decodedImage(avatarURL) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .background(Self.color(for: name).opacity(0.35))
                .clipShape(Circle())
        } else {
            ZStack {
                Circle().fill(Self.color(for: name).gradient)
                Text(Self.initials(of: name))
                    .font(.system(size: size * 0.4, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        }
    }

    static func initials(of name: String) -> String {
        let parts = name.split(separator: " ").prefix(2).compactMap(\.first)
        if parts.isEmpty { return "?" }
        return String(parts).uppercased()
    }

    /// Stable hash → hue. NOT `String.hashValue` (randomly seeded per launch —
    /// the avatar would change color every app start).
    static func color(for name: String) -> Color {
        var hash: UInt32 = 2166136261
        for byte in name.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.72)
    }

    // MARK: - Emoji avatars ("emoji:😎|#4DABF7") — the in-app designer's
    // output: an emoji face on a colored gradient disc. Rendered natively,
    // so it stays crisp at every size and costs nothing to sync.

    static func emojiAvatarString(emoji: String, colorHex: String) -> String {
        "emoji:\(emoji)|\(colorHex)"
    }

    static func parseEmojiAvatar(_ value: String) -> (String, Color)? {
        guard value.hasPrefix("emoji:") else { return nil }
        let body = String(value.dropFirst("emoji:".count))
        guard let bar = body.lastIndex(of: "|") else { return nil }
        let emoji = String(body[..<bar])
        guard !emoji.isEmpty, let color = Color(hex: String(body[body.index(after: bar)...]))
        else { return nil }
        return (emoji, color)
    }

    // MARK: - Data-URL decoding (cached — avatars render on every map frame)

    private static let cache = NSCache<NSString, UIImage>()

    static func decodedImage(_ dataURL: String) -> UIImage? {
        guard dataURL.hasPrefix("data:image") else { return nil }
        let key = NSString(string: String(dataURL.suffix(64)) + String(dataURL.count))
        if let hit = cache.object(forKey: key) { return hit }
        guard let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
              let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// Normalizes a captured avatar (Memoji sticker or photo) into a compact
    /// data URL: 240pt square, PNG when it has transparency (stickers),
    /// JPEG otherwise (photos).
    static func makeDataURL(from image: UIImage) -> String? {
        let side: CGFloat = 240
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
            .image { _ in
                let aspect = max(side / max(image.size.width, 1), side / max(image.size.height, 1))
                let w = image.size.width * aspect, h = image.size.height * aspect
                image.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
            }
        let hasAlpha = image.cgImage.map {
            [.premultipliedLast, .premultipliedFirst, .last, .first].contains($0.alphaInfo)
        } ?? false
        if hasAlpha, let png = scaled.pngData() {
            return "data:image/png;base64," + png.base64EncodedString()
        }
        if let jpeg = scaled.jpegData(compressionQuality: 0.8) {
            return "data:image/jpeg;base64," + jpeg.base64EncodedString()
        }
        return nil
    }
}

/// The settings-button icon used in every page header: the user's own
/// avatar once they've set one up, the generic person symbol before that.
struct ProfileButtonIcon: View {
    @ObservedObject private var supabase = ArcSupabase.shared
    var size: CGFloat = 34

    var body: some View {
        if let user = supabase.currentUser,
           user.avatar_url != nil || !user.display_name.isEmpty {
            FriendAvatar(name: user.display_name.isEmpty ? "You" : user.display_name,
                         size: size, avatarURL: user.avatar_url)
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: size))
                .foregroundStyle(Color(.systemGray3), Color(.systemGray5))
        }
    }
}

extension Color {
    /// "#4DABF7" → Color. Nil on anything malformed.
    init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

extension String {
    /// "CH" → 🇨🇭 (regional-indicator pair). Unknown/malformed codes fall
    /// back to a neutral flag rather than garbage.
    static func flag(forRegion code: String) -> String {
        let scalars = code.uppercased().unicodeScalars.compactMap { scalar in
            UnicodeScalar(127397 + scalar.value)
        }
        guard scalars.count == 2 else { return "🏳️" }
        return String(String.UnicodeScalarView(scalars))
    }
}
