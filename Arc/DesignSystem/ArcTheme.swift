import SwiftUI

/// Flighty-parity design tokens. Built on semantic system colors + materials so
/// light/dark tracks the system automatically.
enum ArcTheme {
    // Status
    static let onTime = Color(red: 0.20, green: 0.78, blue: 0.35)   // #34C759
    static let late   = Color(red: 1.00, green: 0.23, blue: 0.19)   // #FF3B30
    static let action = Color(red: 0.04, green: 0.52, blue: 1.00)   // #0A84FF
    static let gate   = Color(red: 1.00, green: 0.80, blue: 0.00)   // #FFCC00
    /// Map route arcs specifically — brighter/lighter than `action` on purpose,
    /// so the great-circle line reads clearly against both map styles instead
    /// of blending into standard UI blue.
    static let routeLine = Color(red: 0.30, green: 0.69, blue: 1.00)   // #4DB0FF

    static func timeColor(late: Bool) -> Color { late ? Self.late : Self.onTime }

    // Type scale (system SF Pro)
    static let screenTitle = Font.system(size: 34, weight: .heavy)
    static let sheetTitle  = Font.system(size: 22, weight: .bold)
    static let bigTime     = Font.system(size: 40, weight: .regular)
    static let iata        = Font.system(size: 16, weight: .bold)
    static let cityPair    = Font.system(size: 22, weight: .semibold)
    static let bodyEmph    = Font.system(size: 15, weight: .semibold)
    static let caption     = Font.system(size: 13, weight: .regular)
    static let captionEmph = Font.system(size: 13, weight: .semibold)
    static let tag         = Font.system(size: 13, weight: .medium)
    static let countdownNum = Font.system(size: 30, weight: .heavy)
    static let countdownUnit = Font.system(size: 11, weight: .bold)

    // Metrics
    static let sheetCorner: CGFloat = 22
    static let cardCorner: CGFloat = 14
    static let gatePillCorner: CGFloat = 8
    static let screenPad: CGFloat = 20
}

/// Yellow gate pill used in flight detail (`↗ C8`).
struct GatePill: View {
    let arrow: String   // "arrow.up.right" or "arrow.down.right"
    let gate: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: arrow).font(.system(size: 11, weight: .bold))
            Text(gate).font(.system(size: 17, weight: .bold))
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(ArcTheme.gate, in: RoundedRectangle(cornerRadius: ArcTheme.gatePillCorner))
    }
}
