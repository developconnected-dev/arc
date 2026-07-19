import SwiftUI

/// Arc design tokens — dark aviation theme with cyan accent.
enum ArcColor {
    static let accent = Color(red: 0.055, green: 0.647, blue: 0.914) // #0EA5E9
    static let accentDim = accent.opacity(0.3)
    static let bg = Color(red: 0.07, green: 0.07, blue: 0.09)       // Near-black
    static let card = Color(red: 0.11, green: 0.11, blue: 0.12)     // Dark gray card
    static let text = Color.white
    static let textMuted = Color.white.opacity(0.5)
    static let textDim = Color.white.opacity(0.3)
    static let border = Color.white.opacity(0.08)

    // Status
    static let onTime = Color.green
    static let delayed = Color.orange
    static let cancelled = Color.red
    static let landed = Color.green.opacity(0.8)

    static func statusColor(for status: FlightStatus, delay: Int = 0) -> Color {
        switch status {
        case .scheduled: delay > 0 ? .orange : .green
        case .active: delay > 15 ? .orange : .green
        case .landed: .green
        case .cancelled: .red
        case .diverted: .orange
        }
    }
}

enum ArcType {
    static let heroLarge = Font.system(size: 34, weight: .heavy, design: .rounded)
    static let heroSmall = Font.system(size: 24, weight: .bold, design: .rounded)
    static let title = Font.system(size: 18, weight: .bold)
    static let body = Font.system(size: 15, weight: .regular)
    static let bodyEmph = Font.system(size: 15, weight: .semibold)
    static let caption = Font.system(size: 12, weight: .regular)
    static let captionEmph = Font.system(size: 12, weight: .semibold)
    static let mono = Font.system(size: 16, weight: .semibold, design: .monospaced)
    static let monoSmall = Font.system(size: 13, weight: .medium, design: .monospaced)
    static let data = Font.system(size: 28, weight: .heavy, design: .rounded)
}

enum ArcRadius {
    static let card: CGFloat = 16
    static let button: CGFloat = 12
    static let small: CGFloat = 8
}

enum ArcSpace {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let screen: CGFloat = 16
}
