import Foundation

/// Deployment-specific endpoints, read from the bundle's Info.plist, which the
/// build fills in from Config/Secrets.xcconfig. Kept out of source so a public
/// checkout carries no live backend address or key; a checkout without the
/// file falls back to a local `wrangler dev` Worker and no Supabase.
enum ArcConfig {
    private static func value(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let v = raw.trimmingCharacters(in: .whitespaces)
        return v.isEmpty || v.hasPrefix("$(") ? nil : v
    }

    /// The shipping Worker, as a string so Settings can show and restore it.
    static let defaultAPIEndpoint: String =
        value("ArcAPIHost").map { "https://\($0)" } ?? "http://localhost:8787"

    static var defaultAPIURL: URL { URL(string: defaultAPIEndpoint)! }

    static let supabaseURL: String? = value("ArcSupabaseHost").map { "https://\($0)" }
    static let supabaseAnonKey: String? = value("ArcSupabaseAnonKey")
}
