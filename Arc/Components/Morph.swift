import SwiftUI

/// The row is the detail. A tapped My Trips row never fades or gets
/// replaced: one copy of it, drawn in an overlay of the sheet, glides from
/// the row's slot to the top of the detail on open and back on close,
/// while the list and the detail crossfade underneath it. Both copies in
/// the trees hide while the overlay's is travelling, so there is never more
/// than one card on screen.
///
/// Driven by hand rather than by `matchedGeometryEffect`: inside a List's
/// cell hosting the matched copy never moved, and with two sources the
/// arriving copy sat on the departing one's frame and snapped at the end.
/// Here the frames are measured and the card is placed — nothing to guess.
enum Morph {
    /// Everything that is not the hero is only there while its side is
    /// mostly present: gone in the first part of a departure, back in the
    /// last part of an arrival.
    static func presence(_ progress: Double) -> Double { ramp(progress, from: 0.55, to: 1) }

    static func ramp(_ x: Double, from a: Double, to b: Double) -> Double {
        min(max((x - a) / (b - a), 0), 1)
    }

    /// How long after the detail appears its sections are laid out: the
    /// whole tree on the first frame cost ~200 ms and froze the glide.
    static let sectionsDelay: Double = 0.05
    /// When the travelling copy has landed and the trees' copies take over.
    static let travelDuration: Double = 0.5

    /// Where the detail's card is, in the sheet content's coordinates: the
    /// first thing under the grabber, spanning the content width less the
    /// row's inset that the detail undoes (`FlightDetailView.hero`).
    static func target(in size: CGSize, rowHeight: CGFloat) -> CGRect {
        CGRect(x: 2, y: 0, width: size.width - 4, height: rowHeight)
    }
}

enum MorphSide { case list, detail }

/// Where the hero copies are, in global coordinates, reported by the
/// views themselves — every list row and the detail's card.
@Observable @MainActor
final class HeroFrames {
    /// Keyed by the hero key: a flight's id for the user's own rows, the
    /// feed item's id for a friend's — see `heroCopy(key:side:)`.
    var rows: [String: CGRect] = [:]
    /// The detail's card. Its position is known in advance (`Morph.target`);
    /// what matters is WHEN it reports — after the detail's first, heavy
    /// layout — because a glide started before that has no frame to start
    /// from and snaps. Whoever is waiting for that moment is told.
    var detail: CGRect? {
        didSet {
            guard detail != nil, let waiting = onDetail else { return }
            onDetail = nil
            waiting()
        }
    }
    var onDetail: (() -> Void)?
}

/// A side's opacity, shaped on the travel progress: the list is present
/// at 0, the detail at 1.
struct SidePresence: ViewModifier, Animatable {
    let side: MorphSide
    var progress: Double
    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        content.opacity(Morph.presence(side == .list ? 1 - progress : progress))
    }
}

/// The travelling copy's frame, interpolated between the row's slot and
/// the detail's card.
struct HeroPlacement: ViewModifier, Animatable {
    var progress: Double
    let from: CGRect
    let to: CGRect
    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let p = min(max(progress, 0), 1)
        let r = CGRect(x: from.minX + (to.minX - from.minX) * p,
                       y: from.minY + (to.minY - from.minY) * p,
                       width: from.width + (to.width - from.width) * p,
                       height: from.height + (to.height - from.height) * p)
        content
            .frame(width: r.width, height: r.height, alignment: .topLeading)
            .clipped()
            .position(x: r.midX, y: r.midY)
    }
}

private struct HeroFramesKey: EnvironmentKey {
    static let defaultValue: HeroFrames? = nil
}
private struct HeroTravellingKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// Set once at the tab sheet; nil (previews, tests, friend sheets)
    /// means nothing is measured and nothing travels.
    var heroFrames: HeroFrames? {
        get { self[HeroFramesKey.self] }
        set { self[HeroFramesKey.self] = newValue }
    }
    /// The flight whose card is travelling in the overlay right now; both
    /// trees hide their own copy of it.
    var heroTravelling: String? {
        get { self[HeroTravellingKey.self] }
        set { self[HeroTravellingKey.self] = newValue }
    }
}

private struct HeroReporter: ViewModifier {
    @Environment(\.heroFrames) private var frames
    @Environment(\.heroTravelling) private var travelling
    let key: String
    let side: MorphSide
    func body(content: Content) -> some View {
        content
            // `hidden()` rather than `opacity(0)`: inside a List cell the
            // faded parent rasterises the row, and a zero opacity on the
            // child was still drawn for the length of the fade.
            .hidden(travelling == key)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                switch side {
                case .list: frames?.rows[key] = rect
                case .detail: frames?.detail = rect
                }
            }
    }
}

private extension View {
    @ViewBuilder func hidden(_ isHidden: Bool) -> some View {
        if isHidden { self.hidden() } else { self }
    }
}

extension View {
    /// Marks this card as a hero copy: it reports where it is, and hides
    /// while the overlay's copy is travelling in its place.
    func heroCopy(for flight: Flight, side: MorphSide) -> some View {
        modifier(HeroReporter(key: flight.id.uuidString, side: side))
    }
    /// The same, keyed explicitly — a friend's row is keyed by its feed item.
    func heroCopy(key: String, side: MorphSide) -> some View {
        modifier(HeroReporter(key: key, side: side))
    }
}

extension ArcTheme {
    /// The one curve the moment rides: the hero's glide and the crossfade
    /// around it. A firm spring with a small settle rather than a bounce.
    static let morph: Animation = .spring(response: 0.36, dampingFraction: 0.84)
}
