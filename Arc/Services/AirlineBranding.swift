import SwiftUI

/// Maps an airline IATA code to a bundled logo asset (if present) and a
/// deterministic tail color + initials for the fallback chip.
enum AirlineBranding {
    /// Asset-catalog name for a bundled logo, or nil to use the fallback chip.
    static func logoAssetName(iata: String) -> String? {
        let key = iata.uppercased()
        return UIImage(named: "airline-\(key)") != nil ? "airline-\(key)" : nil
    }

    /// Deterministic tail color derived from the IATA code (stable per airline).
    static func tailColor(iata: String) -> Color {
        let palette: [Color] = [
            .red, .blue, .orange, .green, .purple, .pink, .teal, .indigo
        ]
        let sum = iata.uppercased().unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }

    static func initials(iata: String) -> String { String(iata.uppercased().prefix(2)) }
}
