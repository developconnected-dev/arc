import SwiftUI

/// Legacy token names retained for the (frozen) Friends/Settings screens.
/// New work should use `ArcTheme`. These now resolve to adaptive system colors.
enum ArcColor {
    static let accent = ArcTheme.action
    static let accentDim = ArcTheme.action.opacity(0.3)
    static let bg = Color(.systemBackground)
    static let card = Color(.secondarySystemBackground)
    static let text = Color(.label)
    static let textMuted = Color(.secondaryLabel)
    static let textDim = Color(.tertiaryLabel)
    static let border = Color(.separator)

    static let onTime = ArcTheme.onTime
    static let delayed = Color(red: 1.0, green: 0.58, blue: 0.0)
    static let cancelled = ArcTheme.late
    static let landed = ArcTheme.onTime

    static func statusColor(for status: FlightStatus, delay: Int = 0) -> Color {
        switch status {
        case .scheduled: delay > 0 ? delayed : onTime
        case .boarding: onTime
        case .gateClosed: delayed
        case .active: delay > 15 ? delayed : onTime
        case .landed: onTime
        case .cancelled: cancelled
        case .diverted: delayed
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
