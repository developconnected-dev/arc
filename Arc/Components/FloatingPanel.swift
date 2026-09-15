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
        .overlay(alignment: .topTrailing) { recenter(current) }
        .offset(y: current - layout.panelHighestTop)
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
                if dragStart == nil { dragStart = start }
                liveTop = layout.clampPanelTop(start + value.translation.height, headerHeight: headerHeight)
            }
            .onEnded { _ in
                // Usually a no-op: `dragging` already flipped false and the
                // `onChange` above already settled `top` and cleared this.
                if let liveTop { top = liveTop }
                liveTop = nil
                dragStart = nil
            }
    }

    @ViewBuilder
    private func recenter(_ current: CGFloat) -> some View {
        if let onRecenter {
            let fits = layout.recenterYAbovePanel(panelTop: current) != nil
            RecenterButton(action: onRecenter)
                .padding(.trailing, MyTripsLayout.margin)
                .offset(y: -(MyTripsLayout.gap + MyTripsLayout.control))
                .opacity(fits ? 1 : 0)
                .allowsHitTesting(fits)
                .accessibilityHidden(!fits)
                .animation(.easeOut(duration: 0.15), value: fits)
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
