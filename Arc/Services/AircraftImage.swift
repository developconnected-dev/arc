import Foundation

/// How a given aircraft family is actually shaped, side-on.
///
/// Proportions are fractions of the drawing box, taken from real reference
/// dimensions (fuselage slenderness, fin height, engine placement), so an A320
/// reads as a narrowbody twin, a 747 carries its hump and four engines, and an
/// ATR sits high-winged on props.
///
/// Authored here rather than bundled as artwork on purpose: the silhouette set
/// named in the brief (`planewatch/pw-silhouettes`) does not exist, and the
/// closest public equivalent is GPL-3.0 — viral licensing is not something to
/// entangle an app in. Drawn paths also tint and scale perfectly against the
/// glass UI, with no asset catalogue to maintain.
struct AircraftProfile: Equatable {
    enum Engines: Equatable {
        case underwing(Int)      // jets slung under the wing
        case rearFuselage(Int)   // regional jets, MD-80s
        case turboprop(Int)      // props on the wing leading edge
    }
    enum Deck: Equatable {
        case single
        case foreHump            // 747: raised forward deck
        case double              // A380: full-length upper deck
    }
    enum Tailplane: Equatable {
        case lowSet              // on the rear fuselage
        case tMount              // atop the fin
    }

    var fuselage: CGFloat        // thickness as a fraction of box height
    var noseLength: CGFloat      // how far the nose taper runs back
    var tailUpsweep: CGFloat     // rear fuselage rise
    var finHeight: CGFloat
    var finChord: CGFloat        // fore-aft width of the fin base
    var wingRoot: CGFloat        // where the wing meets the fuselage, 0…1
    var wingChord: CGFloat
    var wingSweep: CGFloat       // how far back the tip trails
    /// Real length-to-height ratio, so a CRJ reads long and slim and an
    /// A380 tall and stubby instead of every family sharing one box.
    var aspect: CGFloat = 3.4
    var engines: Engines
    var deck: Deck = .single
    var tailplane: Tailplane = .lowSet

    // MARK: Families

    /// A320, 737 — the everyday narrowbody twin.
    static let narrowbody = AircraftProfile(
        fuselage: 0.335, noseLength: 0.15, tailUpsweep: 0.055,
        finHeight: 0.44, finChord: 0.16,
        wingRoot: 0.44, wingChord: 0.13, wingSweep: 0.19,
        aspect: 3.2,
        engines: .underwing(2))

    /// A321, 757 — same family, visibly stretched and slimmer for its length.
    static let narrowbodyStretched = AircraftProfile(
        fuselage: 0.315, noseLength: 0.13, tailUpsweep: 0.05,
        finHeight: 0.42, finChord: 0.15,
        wingRoot: 0.46, wingChord: 0.12, wingSweep: 0.18,
        aspect: 3.7,
        engines: .underwing(2))

    /// 787, A350, 777 — twin-aisle: deeper fuselage, larger engines.
    static let widebody = AircraftProfile(
        fuselage: 0.34, noseLength: 0.14, tailUpsweep: 0.06,
        finHeight: 0.45, finChord: 0.18,
        wingRoot: 0.43, wingChord: 0.15, wingSweep: 0.22,
        aspect: 3.9,
        engines: .underwing(2))

    /// A340 — four engines under a twin-aisle wing.
    static let widebodyQuad = AircraftProfile(
        fuselage: 0.33, noseLength: 0.14, tailUpsweep: 0.06,
        finHeight: 0.44, finChord: 0.17,
        wingRoot: 0.43, wingChord: 0.15, wingSweep: 0.22,
        aspect: 4.2,
        engines: .underwing(4))

    /// 747 — the hump is the whole point.
    static let jumbo = AircraftProfile(
        fuselage: 0.335, noseLength: 0.12, tailUpsweep: 0.065,
        finHeight: 0.42, finChord: 0.19,
        wingRoot: 0.45, wingChord: 0.16, wingSweep: 0.24,
        aspect: 3.6,
        engines: .underwing(4), deck: .foreHump)

    /// A380 — upper deck running the full length.
    static let superjumbo = AircraftProfile(
        fuselage: 0.35, noseLength: 0.12, tailUpsweep: 0.05,
        finHeight: 0.4, finChord: 0.2,
        wingRoot: 0.43, wingChord: 0.17, wingSweep: 0.24,
        aspect: 3.0,
        engines: .underwing(4), deck: .double)

    /// CRJ, ERJ — engines on the rear fuselage under a T-tail.
    static let regionalJet = AircraftProfile(
        fuselage: 0.358, noseLength: 0.15, tailUpsweep: 0.05,
        finHeight: 0.42, finChord: 0.16,
        wingRoot: 0.42, wingChord: 0.12, wingSweep: 0.15,
        aspect: 4.6,
        engines: .rearFuselage(2), tailplane: .tMount)

    /// E190/E195, A220 — regional size but underwing engines.
    static let regionalUnderwing = AircraftProfile(
        fuselage: 0.285, noseLength: 0.14, tailUpsweep: 0.05,
        finHeight: 0.41, finChord: 0.15,
        wingRoot: 0.44, wingChord: 0.12, wingSweep: 0.16,
        aspect: 3.4,
        engines: .underwing(2))

    /// ATR, Dash 8 — high wing, props, tall fin, barely any sweep.
    static let turboprop = AircraftProfile(
        fuselage: 0.362, noseLength: 0.12, tailUpsweep: 0.06,
        finHeight: 0.46, finChord: 0.17,
        wingRoot: 0.42, wingChord: 0.11, wingSweep: 0.04,
        aspect: 3.5,
        engines: .turboprop(2), tailplane: .tMount)
}

/// Resolves a free-text or ICAO aircraft type to a profile.
enum AircraftImage {
    /// Ordered so the more specific token wins: "A321" is checked before
    /// "A320", "B77W" before "777". ICAO designators (A20N, B38M, B77W, B789)
    /// resolve as readily as marketing names ("787-9 Dreamliner", "Boeing
    /// 777-300ER", "Airbus A320neo") because spaces and hyphens are stripped
    /// before matching.
    private static let table: [(needle: String, profile: AircraftProfile)] = [
        // Airbus
        ("A388", .superjumbo), ("A380", .superjumbo),
        ("A343", .widebodyQuad), ("A345", .widebodyQuad), ("A346", .widebodyQuad), ("A340", .widebodyQuad),
        ("A359", .widebody), ("A35K", .widebody), ("A350", .widebody),
        ("A332", .widebody), ("A333", .widebody), ("A338", .widebody), ("A339", .widebody), ("A330", .widebody),
        ("A306", .widebody), ("A310", .widebody), ("A300", .widebody),
        ("A21N", .narrowbodyStretched), ("A321", .narrowbodyStretched),
        ("A20N", .narrowbody), ("A320", .narrowbody),
        ("A19N", .narrowbody), ("A319", .narrowbody), ("A318", .narrowbody),
        ("A220", .regionalUnderwing), ("BCS1", .regionalUnderwing), ("BCS3", .regionalUnderwing),
        // Boeing
        ("B741", .jumbo), ("B742", .jumbo), ("B743", .jumbo), ("B744", .jumbo), ("B748", .jumbo), ("747", .jumbo),
        ("B77W", .widebody), ("B77L", .widebody), ("B772", .widebody), ("B773", .widebody),
        ("B778", .widebody), ("B779", .widebody), ("777", .widebody),
        ("B788", .widebody), ("B789", .widebody), ("B78X", .widebody), ("787", .widebody),
        ("B762", .widebody), ("B763", .widebody), ("B764", .widebody), ("767", .widebody),
        ("B752", .narrowbodyStretched), ("B753", .narrowbodyStretched), ("757", .narrowbodyStretched),
        ("B38M", .narrowbody), ("B39M", .narrowbody), ("B3XM", .narrowbody),
        ("B736", .narrowbody), ("B737", .narrowbody), ("B738", .narrowbody), ("B739", .narrowbody),
        ("737", .narrowbody), ("MAX", .narrowbody),
        // Regionals
        ("E290", .regionalUnderwing), ("E295", .regionalUnderwing),
        ("E190", .regionalUnderwing), ("E195", .regionalUnderwing), ("E19", .regionalUnderwing),
        ("E170", .regionalJet), ("E175", .regionalJet), ("E17", .regionalJet), ("E75", .regionalJet),
        ("E145", .regionalJet), ("E135", .regionalJet), ("ERJ", .regionalJet),
        ("CRJ", .regionalJet), ("CR9", .regionalJet), ("CR7", .regionalJet), ("CRK", .regionalJet),
        // Turboprops
        ("AT7", .turboprop), ("AT4", .turboprop), ("ATR", .turboprop),
        ("Q400", .turboprop), ("DH8", .turboprop), ("DHC", .turboprop),
    ]

    static func profile(for type: String?) -> AircraftProfile {
        guard let raw = type?.uppercased(), !raw.isEmpty else { return .narrowbody }
        let text = raw
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        for entry in table where text.contains(entry.needle) { return entry.profile }
        // An unrecognised type is far more likely to be a narrowbody twin than
        // anything else, so that's the fallback rather than a generic blob.
        return .narrowbody
    }

    /// True for twin-aisle families — used for layout decisions, not drawing.
    static func isWide(_ type: String?) -> Bool {
        switch profile(for: type) {
        case .widebody, .widebodyQuad, .jumbo, .superjumbo: return true
        default: return false
        }
    }
}
