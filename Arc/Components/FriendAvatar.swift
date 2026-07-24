import SwiftUI

/// Initials avatar with a deterministic per-person color — no Memoji to pull
/// from, so this is the identity mark everywhere (list rows, map bubbles).
struct FriendAvatar: View {
    let name: String
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle().fill(Self.color(for: name).gradient)
            Text(Self.initials(of: name))
                .font(.system(size: size * 0.4, weight: .heavy))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
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
}
