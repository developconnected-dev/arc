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
    /// Overlap the two surfaces throughout the transition. Delaying each
    /// side until 55% left BOTH invisible at the midpoint, flashing the map
    /// through the sheet on every open and close.
    static func presence(_ progress: Double) -> Double { ramp(progress, from: 0, to: 1) }

    static func ramp(_ x: Double, from a: Double, to b: Double) -> Double {
        min(max((x - a) / (b - a), 0), 1)
    }

    /// The breath between the grabber row (menu and X) and the header's top
    /// line in the tab sheet — `FlightDetailView` pads by it, and the
    /// fallback target below starts there.
    static let detailTopInset: CGFloat = 12

    /// How far above the sheet content's top edge `BottomSheet`'s capsule
    /// centre sits (its 50pt zone keeps 25pt above the capsule and trims
    /// 12pt below it), for the detail's controls to line up with.
    static let grabberCentreAboveContent: CGFloat = 13

    /// Where the detail's card is, in the sheet content's coordinates: the
    /// first thing under the grabber, spanning the content width less the
    /// row's inset that the detail undoes (`FlightDetailView.hero`).
    static func target(in size: CGSize, rowHeight: CGFloat) -> CGRect {
        CGRect(x: 2, y: detailTopInset, width: size.width - 4, height: rowHeight)
    }

    /// The travelling copy's own glass on the floating surface: none at
    /// either end, whole in between, so the card never crosses bare map as
    /// text alone.
    static func travelGlass(_ progress: Double) -> Double {
        min(ramp(progress, from: 0, to: 0.2), 1 - ramp(progress, from: 0.8, to: 1))
    }

    /// How far the floating panel rises while it fades in.
    static let panelRise: CGFloat = 28

    /// A frame measured on the still-rising panel, moved to where it settles.
    /// Pass the progress the header was measured under — `prepare` runs before the glide's animation begins.
    static func settledFrame(_ measured: CGRect, progress: Double) -> CGRect {
        measured.offsetBy(dx: 0, dy: -panelRise * (1 - min(max(progress, 0), 1)))
    }

    /// Where the header lands in the floating panel, for when it has not
    /// reported its frame yet.
    static func panelTarget(panelTop: CGFloat, width: CGFloat, rowHeight: CGFloat) -> CGRect {
        let inset = MyTripsLayout.panelMargin + 16
        return CGRect(x: inset, y: panelTop + MyTripsLayout.panelStrip + detailTopInset,
                      width: width - 2 * inset, height: rowHeight)
    }
}

enum MorphSide { case list, detail }

/// Where the hero copies are, in global coordinates, reported by the
/// views themselves — every list row and the detail's card.
@MainActor
final class HeroFrames {
    // Geometry is an imperative handoff, not UI state. Observing every row
    // measurement invalidated the root while the travelling card was moving.
    /// Keyed by the hero key: a flight's id for the user's own rows, the
    /// feed item's id for a friend's — see `heroCopy(key:side:)`.
    var rows: [String: CGRect] = [:]
    /// Keyed by the same source as the row. Hidden tabs and previous trips
    /// cannot overwrite the destination of the currently opening card.
    var details: [String: CGRect] = [:]

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

/// The floating panel arriving: it fades in with the detail's side and rises
/// the last few points, the grammar Arc's transitions keep.
struct PanelPresence: ViewModifier, Animatable {
    var progress: Double
    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        content
            .opacity(Morph.presence(progress))
            .offset(y: Morph.panelRise * (1 - min(max(progress, 0), 1)))
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
private struct HeroReportsKey: EnvironmentKey {
    static let defaultValue = true
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
    /// False on a copy of the rows that is laid out but not the one showing
    /// (My Trips' folded stack and its unfolded list hold the same cards):
    /// a key reports its frame from one place at a time.
    var heroReports: Bool {
        get { self[HeroReportsKey.self] }
        set { self[HeroReportsKey.self] = newValue }
    }
}

private struct HeroReporter: ViewModifier {
    @Environment(\.heroFrames) private var frames
    @Environment(\.heroTravelling) private var travelling
    @Environment(\.heroReports) private var reports
    let key: String
    let side: MorphSide
    func body(content: Content) -> some View {
        let reports = reports
        return content
            // Keep the same view identity when handing off to the overlay.
            // A conditional hidden() replaced the subtree twice per trip,
            // restarting layout and appearance callbacks during the glide.
            .compositingGroup()
            .opacity(travelling == key ? 0 : 1)
            .animation(nil, value: travelling == key)
            .accessibilityHidden(travelling == key)
            // nil while this copy isn't the one showing; turning it back on
            // changes the value, so it reports again at once.
            .onGeometryChange(for: CGRect?.self) { reports ? $0.frame(in: .global) : nil } action: { rect in
                guard let rect else { return }
                switch side {
                case .list: frames?.rows[key] = rect
                case .detail: frames?.details[key] = rect
                }
            }
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
