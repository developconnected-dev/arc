import SwiftUI

enum Morph {
    /// How far below its place an element starts, and the gap between one
    /// element's start and the next.
    static let rise: CGFloat = 44
    static let stagger: Double = 0.045
    /// The list's own fade. Short, and never overlapping the elements: on
    /// open it is gone before they rise, on close it returns after the last
    /// has dropped — the two phases run in sequence, not on top of each other.
    static let listFade: Animation = .easeInOut(duration: 0.16)
    /// How long the list takes to leave before the elements start rising,
    /// and how long the last element takes to drop before the list returns.
    static let listOut: Double = 0.20
    static let elementsOut: Double = 0.46
    /// Everything done — the hidden view can be removed.
    static let closeTotal: Double = 0.72

    /// Sections laid out after the header (see `FlightDetailView.sectionsIn`)
    /// join the rise at their own turn when they are inserted; on close they
    /// are already there and drop with `RiseIn` like everything else.
    static func sectionInsertion(index: Int) -> AnyTransition {
        .asymmetric(
            insertion: .offset(y: rise).combined(with: .opacity)
                .animation(ArcTheme.morph.delay(Double(index) * stagger)),
            removal: .identity)
    }
}

/// One element of the detail rising into place from below, with the
/// morph's bounce, in its turn. `shown` false is the exact reverse: the
/// same spring drops it back where it came from, and the turns run
/// backwards so the last to arrive is the first to leave.
struct RiseIn: ViewModifier {
    let shown: Bool
    let index: Int
    let count: Int

    var turn: Int { shown ? index : (count - 1 - index) }

    func body(content: Content) -> some View {
        content
            .offset(y: shown ? 0 : Morph.rise)
            .opacity(shown ? 1 : 0)
            .animation(ArcTheme.morph.delay(Double(turn) * Morph.stagger), value: shown)
    }
}

extension View {
    func riseIn(_ shown: Bool, index: Int, of count: Int) -> some View {
        modifier(RiseIn(shown: shown, index: index, count: count))
    }
}

extension ArcTheme {
    /// The one spring every part of the row-to-detail moment rides: the
    /// elements' rise, the sheet's rise, the list's fade. Damping under 1
    /// is the small bounce on landing.
    static let morph: Animation = .spring(response: 0.42, dampingFraction: 0.72)
}
