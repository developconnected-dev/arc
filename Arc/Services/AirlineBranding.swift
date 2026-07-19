import SwiftUI

/// Maps an airline IATA code to a bundled logo asset (if present) and a
/// deterministic tail color + initials for the fallback chip.
enum AirlineBranding {
    /// Asset-catalog name for a bundled logo, or nil to use the fallback chip.
    static func logoAssetName(iata: String) -> String? {
        let key = iata.uppercased()
        return UIImage(named: "airline-\(key)") != nil ? "airline-\(key)" : nil
    }

    /// Brand-ish colors for common carriers (a color is not a logo → trademark-safe).
    private static let brand: [String: Color] = [
        "LX": Color(red: 0.86, green: 0.10, blue: 0.14),  // Swiss red
        "LH": Color(red: 0.02, green: 0.16, blue: 0.40),  // Lufthansa navy
        "U2": Color(red: 1.00, green: 0.40, blue: 0.00),  // easyJet orange
        "W6": Color(red: 0.78, green: 0.06, blue: 0.52),  // Wizz magenta
        "BA": Color(red: 0.16, green: 0.20, blue: 0.47),  // British Airways blue
        "AF": Color(red: 0.00, green: 0.20, blue: 0.55),  // Air France blue
        "KL": Color(red: 0.00, green: 0.64, blue: 0.87),  // KLM sky
        "DL": Color(red: 0.60, green: 0.10, blue: 0.20),  // Delta
        "AA": Color(red: 0.12, green: 0.36, blue: 0.62),  // American
        "UA": Color(red: 0.00, green: 0.27, blue: 0.55),  // United
        "B6": Color(red: 0.00, green: 0.32, blue: 0.62),  // JetBlue
        "EK": Color(red: 0.82, green: 0.10, blue: 0.16),  // Emirates
        "QR": Color(red: 0.42, green: 0.09, blue: 0.24),  // Qatar
        "TK": Color(red: 0.78, green: 0.10, blue: 0.16),  // Turkish
        "GQ": Color(red: 0.10, green: 0.16, blue: 0.55),  // Sky Express
        "OS": Color(red: 0.80, green: 0.05, blue: 0.10),  // Austrian
        "SN": Color(red: 0.00, green: 0.32, blue: 0.60),  // Brussels
        "IB": Color(red: 0.78, green: 0.06, blue: 0.20),  // Iberia
        "AZ": Color(red: 0.00, green: 0.30, blue: 0.55),  // ITA
        "VY": Color(red: 0.95, green: 0.75, blue: 0.00),  // Vueling
    ]

    /// Deterministic tail color: real brand color if known, else stable hash color.
    static func tailColor(iata: String) -> Color {
        let key = iata.uppercased()
        if let c = brand[key] { return c }
        let palette: [Color] = [.red, .blue, .orange, .green, .purple, .pink, .teal, .indigo]
        let sum = key.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }

    static func initials(iata: String) -> String { String(iata.uppercased().prefix(2)) }
}
