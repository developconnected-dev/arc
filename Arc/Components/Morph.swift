import SwiftUI

/// The elements a My Trips row and the flight detail have in common. Each
/// pair shares a geometry id, so switching from list to detail under a
/// spring animation moves the element from its row frame to its detail
/// frame — the row becomes the detail.
enum MorphElement: String {
    case logo, number, cities, route, status

    func id(for flight: Flight) -> String { "\(rawValue)-\(flight.id.uuidString)" }

    /// Text steps up in size between row and detail; animating its frame
    /// would re-wrap it every frame, so text only travels, and the two sizes
    /// crossfade. The logo and the status block resize cleanly.
    var properties: MatchedGeometryProperties {
        switch self {
        case .logo, .status: .frame
        case .number, .cities, .route: .position
        }
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
