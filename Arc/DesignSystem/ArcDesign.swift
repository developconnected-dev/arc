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

