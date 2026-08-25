import Foundation

/// Which APNs host this install's push tokens actually belong to.
///
/// The answer is the `aps-environment` entitlement, and that comes from the
/// SIGNING PROFILE, not from the build configuration. Deciding it with
/// `#if DEBUG` worked for the two builds anyone means to make — a Debug run
/// (development profile, sandbox token) and a TestFlight build (distribution
/// profile, production token) — and was wrong for the one people actually
/// reach for in between.
///
/// A RELEASE build installed to a device with a development profile is exactly
/// what you get from an archive, and it is the fastest way to put a real build
/// on a real phone without waiting for TestFlight. That build holds a SANDBOX
/// token and, under `#if DEBUG`, told the Worker "production". Every push then
/// went to api.push.apple.com, came back BadDeviceToken — correctly, the token
/// is not valid for that host — and the token was dropped as dead. No alert, no
/// Live Activity, no error anywhere the phone could show it.
///
/// So ask the profile. It is the same thing APNs itself is going by.
enum APNsEnvironment {

    /// Resolved once: the profile cannot change without the app being replaced.
    static let current: String = resolve()

    /// The APNs host named by a provisioning profile's `aps-environment`, or
    /// nil when the profile does not name one.
    ///
    /// Only the two values Apple issues are recognised. Anything else — a
    /// truncated profile, a key with no value, a string Apple adds later — is
    /// nil rather than a guess, because guessing here is the whole bug: a
    /// wrong answer sends every push to a host that will refuse it, and the
    /// refusal looks exactly like a token that has gone away.
    static func host(inProfile text: String) -> String? {
        guard let key = text.range(of: "<key>aps-environment</key>") else { return nil }
        // Bounded, so a later `<string>` belonging to some other key can never
        // be read as this one's value.
        let tail = text[key.upperBound...].prefix(120)
        guard let open = tail.range(of: "<string>"),
              let close = tail.range(of: "</string>"),
              open.upperBound <= close.lowerBound else { return nil }
        switch String(tail[open.upperBound..<close.lowerBound]) {
        case "development": return "sandbox"
        case "production":  return "production"
        default:            return nil
        }
    }

    private static func resolve() -> String {
        // A provisioning profile is CMS-wrapped, so the plist sits inside
        // binary noise. Latin-1 maps every byte to a character, which is what
        // makes the blob searchable as text instead of failing to decode.
        if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .isoLatin1),
           let host = host(inProfile: text) {
            return host
        }
        // No embedded profile at all is the Simulator, whose tokens are
        // sandbox tokens; the old rule is still the right one there.
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }
}
