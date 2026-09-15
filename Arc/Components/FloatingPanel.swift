import SwiftUI

/// My Trips' detail container: a glass panel floating above the tab bar.
/// Its top strip drags it smoothly between the top row and the header, and
/// it rests wherever it is released — no detents, and no drag ever closes it.
///
/// Like `BottomSheet`, per-frame drag state lives one level down, so a drag
/// never re-evaluates the root. Unlike a resizing container, the content
/// keeps ONE height (the tallest the panel can be) and is masked: while the
/// finger moves only an offset, a mask and the glass shape change, so the
/// detail's scroll view never relays out mid-drag.
///
/// The caller places this view with its top edge at `layout.panelHighestTop`.
struct FloatingPanel<Content: View>: View {
    let layout: MyTripsLayout
    let headerHeight: CGFloat
    /// The settled top edge, in screen points. Written once per drag, on release.
    @Binding var top: CGFloat
    var onRecenter: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        FloatingPanelChrome(layout: layout, headerHeight: headerHeight, top: $top,
                            onRecenter: onRecenter, content: content())
    }
}

private struct FloatingPanelChrome<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let layout: MyTripsLayout
    let headerHeight: CGFloat
    @Binding var top: CGFloat
    let onRecenter: (() -> Void)?
    let content: Content

    /// The finger's top edge while a drag is live; nil otherwise.
    @State private var liveTop: CGFloat?
    @State private var dragStart: CGFloat?
    /// True for the lifetime of the gesture, including a system cancellation
    /// that skips `onEnded` — the only reliable way to notice one.
    @GestureState private var dragging = false
    /// The detail's scroll view, for keeping a bottom-scrolled detail pinned
    /// to the panel's edge while it rises (see `pinToBottomEdge`).
    @State private var scrollLink = PanelScrollLink()

    var body: some View {
        // A stale settled `top` (from a layout change while the panel was
        // off-screen) can never hide the header, even for one frame.
        let current = layout.clampPanelTop(liveTop ?? top, headerHeight: headerHeight)
        let tallest = layout.panelBottom - layout.panelHighestTop
        let visible = max(0, layout.panelBottom - current)
        // The detail keeps the tallest height; what hangs below the panel's
        // edge stays reachable through an inset that follows the SETTLED top,
        // so it changes once per drag, not per frame.
        let hiddenBelow = max(0, top - layout.panelHighestTop)

        ZStack(alignment: .top) {
            Color.clear
                .frame(height: visible)
                .glassEffect(ArcTheme.tripGlass, in: .rect(cornerRadius: ArcTheme.panelCorner))
            VStack(spacing: 0) {
                strip
                    // Same geometry as BottomSheet's grabber: a 50 pt target
                    // taking 38 pt of layout, so FlightDetailView's menu and X
                    // (offset onto the strip) land exactly where they did.
                    .padding(.bottom, -12)
                content
                    .contentMargins(.bottom, hiddenBelow, for: .scrollContent)
                    .environment(\.panelScroll, scrollLink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(height: tallest, alignment: .top)
            .mask(alignment: .top) {
                RoundedRectangle(cornerRadius: ArcTheme.panelCorner, style: .continuous)
                    .frame(height: visible)
            }
        }
        .frame(height: tallest, alignment: .top)
        // A mask hides but still hit-tests: without this, the detail hanging
        // below a lowered panel would swallow taps meant for the tab bar.
        .contentShape(.interaction, TopSlice(height: visible))
        .padding(.horizontal, MyTripsLayout.panelMargin)
        .modifier(PanelTopPlacement(top: current, layout: layout, onRecenter: onRecenter))
        // A cancelled gesture (a system alert, a scroll steal) never calls
        // `onEnded`; without this the panel would freeze at `liveTop` forever.
        .onChange(of: dragging) { _, isDragging in
            if !isDragging, let live = liveTop {
                top = live
                liveTop = nil
                dragStart = nil
            }
        }
    }

    private var strip: some View {
        Capsule().fill(Color(.tertiaryLabel))
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .contentShape(Rectangle())
            .gesture(drag)
            .accessibilityElement()
            .accessibilityIdentifier("trip-panel-strip")
            .accessibilityLabel("Trip details size")
            .accessibilityAdjustableAction { direction in
                let next = direction == .increment ? top - 120 : top + 120
                withAnimation(reduceMotion ? nil : ArcTheme.panelSettle) {
                    top = layout.clampPanelTop(next, headerHeight: headerHeight)
                }
            }
    }

    /// `.global`, as in BottomSheet: the strip moves with the offset this
    /// gesture drives, and a local frame would feed that motion back into the
    /// next translation and jitter at the clamps.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                let start = dragStart ?? (liveTop ?? top)
                if dragStart == nil {
                    dragStart = start
                    scrollLink.beginDrag(settledInset: max(0, top - layout.panelHighestTop))
                }
                let live = layout.clampPanelTop(start + value.translation.height, headerHeight: headerHeight)
                liveTop = live
                scrollLink.pinToBottomEdge(liveInset: max(0, live - layout.panelHighestTop))
            }
            .onEnded { _ in
                // Usually a no-op: `dragging` already flipped false and the
                // `onChange` above already settled `top` and cleared this.
                if let liveTop { top = liveTop }
                liveTop = nil
                dragStart = nil
            }
    }
}

/// Places the panel at its top edge and the recenter circle above it, both
/// from the same animated value. The circle used to fade on its own 0.15 s
/// curve keyed to whether it fits: on a programmatic move (Terminal map
/// lowering a tall panel) that flipped with the target, so the circle raced
/// ahead of the panel's spring onto the X, and faded in by the top row
/// before the panel had moved away from it. Now it fades over the last few
/// points before it would crowd the top row, wherever the panel really is.
private struct PanelTopPlacement: ViewModifier, Animatable {
    var top: CGFloat
    let layout: MyTripsLayout
    let onRecenter: (() -> Void)?

    nonisolated var animatableData: CGFloat {
        get { top }
        set { top = newValue }
    }

    /// How far past the closest allowed position the circle fades.
    private static let fade: CGFloat = 16

    func body(content: Content) -> some View {
        let fits = layout.recenterYAbovePanel(panelTop: top) != nil
        let room = top - MyTripsLayout.gap - MyTripsLayout.control - (layout.topBarBottom + MyTripsLayout.gap)
        content
            .overlay(alignment: .topTrailing) {
                if let onRecenter {
                    RecenterButton(action: onRecenter)
                        .padding(.trailing, MyTripsLayout.margin)
                        .offset(y: -(MyTripsLayout.gap + MyTripsLayout.control))
                        .opacity(Double(min(max(room / Self.fade, 0), 1)))
                        .allowsHitTesting(fits)
                        .accessibilityHidden(!fits)
                }
            }
            .offset(y: top - layout.panelHighestTop)
    }
}

/// The panel's handle on the detail's scroll view.
///
/// The detail keeps the tallest height, and what hangs below a lowered
/// panel stays reachable through a bottom inset that follows the settled
/// top. Scrolled to the bottom, that inset is in view below the panel's
/// edge; raising the panel lifted it into sight as empty glass, and the
/// release then shrank it and the content fell by the whole drag. A
/// resizing sheet would instead reveal rows above while the last one stays
/// on the edge — so while the panel rises, the detail scrolls up by exactly
/// the inset that would show, in the same update. On release the offset is
/// already the new maximum, so shrinking the inset moves nothing.
@MainActor
final class PanelScrollLink {
    /// Written by the detail's scroll view as it scrolls; never observed.
    var geometry: ScrollGeometry?
    var scrollTo: ((CGFloat) -> Void)?
    private var start: (offset: CGFloat, insetInView: CGFloat)?
    private var shift: CGFloat = 0
    /// The lowest offset the scroll view rests at: its top inset, negated.
    private var topLimit: CGFloat = 0

    func beginDrag(settledInset: CGFloat) {
        shift = 0
        guard let g = geometry else { start = nil; return }
        // Only a detail that overflows its viewport without the panel's inset
        // has a last row to keep on the edge. A short one (an invite
        // preview) always shows empty viewport below its content, and pinning
        // it scrolled the content up past its top.
        let overflows = g.contentSize.height + g.contentInsets.top
            + max(0, g.contentInsets.bottom - settledInset) > g.containerSize.height
        // How much of the bottom inset the viewport shows right now.
        let inView = min(max(0, g.visibleRect.maxY - g.contentSize.height), settledInset)
        start = overflows && inView > 0 ? (g.contentOffset.y, inView) : nil
        topLimit = -g.contentInsets.top
    }

    /// `liveInset` is how much of the viewport hangs below the panel's edge.
    func pinToBottomEdge(liveInset: CGFloat) {
        guard let start else { return }
        let next = max(0, start.insetInView - liveInset)
        guard next != shift else { return }
        shift = next
        scrollTo?(max(topLimit, start.offset - next))
    }
}

private struct PanelScrollKey: EnvironmentKey {
    static let defaultValue: PanelScrollLink? = nil
}

extension EnvironmentValues {
    /// Set by `FloatingPanel` on its content; nil everywhere else.
    var panelScroll: PanelScrollLink? {
        get { self[PanelScrollKey.self] }
        set { self[PanelScrollKey.self] = newValue }
    }
}

/// Applied to a scroll view that may sit in a `FloatingPanel`: reports its
/// geometry to the panel and lets the panel set its offset. A no-op outside one.
struct PanelScrollReader: ViewModifier {
    @Environment(\.panelScroll) private var link
    @State private var position = ScrollPosition()

    func body(content: Content) -> some View {
        if let link {
            content
                .scrollPosition($position)
                .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in
                    link.geometry = geometry
                }
                .onAppear {
                    let position = $position
                    link.scrollTo = { y in DispatchQueue.main.async { position.wrappedValue.scrollTo(y: y) } }
                }
        } else {
            content
        }
    }
}

/// The top `height` points of a view: the part of a masked, offset view that
/// is actually on screen, for hit-testing (a mask alone still hit-tests).
struct TopSlice: Shape {
    var height: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(max(height, 0), rect.height)))
    }
}
