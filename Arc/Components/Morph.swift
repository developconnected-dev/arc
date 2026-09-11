import SwiftUI

/// The elements a My Trips row and the flight detail have in common. Each
/// pair shares a geometry id, so switching from list to detail under a
/// spring animation moves the element from its row frame to its detail
/// frame — the row becomes the detail.
enum MorphElement: String {
    case logo, number, cities, route, status

    func id(for flight: Flight) -> String { "\(rawValue)-\(flight.id.uuidString)" }

    /// Text steps up in size between row and detail; animating its frame
    /// would re-wrap it every frame ("Landi / ng in…" was seen mid-flight),
    /// so text only travels and the two sizes crossfade. Only the logo, a
    /// square that goes from 20 to 34 points, resizes cleanly.
    var properties: MatchedGeometryProperties {
        switch self {
        case .logo: .frame
        case .number, .cities, .route, .status: .position
        }
    }
}

/// A fade that rides the morph's own spring but is shaped so the two
/// layers never sit half-transparent on top of each other. Attaching a
/// faster animation to the transition instead would override the spring
/// for the whole subtree — on close the elements stopped travelling and the
/// sheet dropped in two frames — so the curve is in the opacity, not in the
/// timing. `eager` front-loads the fade (1 − (1 − p)^k), otherwise it is
/// back-loaded (p^k); `k` sets how hard.
private struct MorphFade: ViewModifier, Animatable {
    var progress: Double
    let eager: Bool
    let k: Double
    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let p = min(max(progress, 0), 1)
        content.opacity(eager ? 1 - pow(1 - p, k) : pow(p, k))
    }
}

extension MorphElement {
    private static func fade(eager: Bool, k: Double) -> AnyTransition {
        .modifier(active: MorphFade(progress: 0, eager: eager, k: k),
                  identity: MorphFade(progress: 1, eager: eager, k: k))
    }

    /// The list. Out hard and early on open, so the old rows never show
    /// through the travelling elements; in moderately late on close, so the
    /// row is there to receive its elements as they land.
    static var leaving: AnyTransition {
        .asymmetric(insertion: fade(eager: false, k: 2), removal: fade(eager: false, k: 3))
    }

    /// The detail. In early on open — its elements are the ones travelling,
    /// so they must be visible from the first frame; out moderately early
    /// on close, so the travelling copies hand off to the row rather than
    /// linger on top of it.
    static var arriving: AnyTransition {
        .asymmetric(insertion: fade(eager: true, k: 3), removal: fade(eager: false, k: 2))
    }
}

private struct MorphNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    /// Set once at the sheet; nil (previews, tests, friend sheets) means no morph.
    var morphNamespace: Namespace.ID? {
        get { self[MorphNamespaceKey.self] }
        set { self[MorphNamespaceKey.self] = newValue }
    }
}

private struct MorphModifier: ViewModifier {
    @Environment(\.morphNamespace) private var namespace
    let element: MorphElement
    let flight: Flight

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: element.id(for: flight), in: namespace,
                                          properties: element.properties, anchor: .leading)
        } else {
            content
        }
    }
}

extension View {
    func morph(_ element: MorphElement, for flight: Flight) -> some View {
        modifier(MorphModifier(element: element, flight: flight))
    }
}

extension ArcTheme {
    /// The one spring every part of the row-to-detail moment rides: the
    /// elements' travel, the sheet's rise, the sections' arrival. Damping
    /// under 1 is the small bounce on landing.
    static let morph: Animation = .spring(response: 0.42, dampingFraction: 0.72)
}
