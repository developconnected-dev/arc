import SwiftUI

/// Standalone so it isn't parameterized by `BottomSheet`'s generic Content
/// (a nested enum in a generic type would be a distinct type per Content).
enum SheetDetent: CaseIterable {
    case small, medium, large
    var fraction: CGFloat { switch self { case .small: 0.32; case .medium: 0.58; case .large: 0.94 } }
}

/// A draggable, multi-detent bottom sheet that sits in a ZStack over the map,
/// so a floating tab bar can be layered above it. The drag gesture lives on the
/// top grabber zone only, leaving any ScrollView inside `content` free to scroll.
struct BottomSheet<Content: View>: View {
    @Binding var detent: SheetDetent
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geo in
            // `content()` is called exactly once per `BottomSheet.body` run —
            // which only happens when `detent` changes or the caller hands us
            // a genuinely new closure (e.g. the active tab changed). Anything
            // that changes on every single frame of an active drag lives one
            // level down, on SheetChrome, so a drag never forces SwiftUI to
            // re-walk `content`'s own body (re-filtering/re-sorting the flight
            // list, rebuilding every row) 60-120 times a second. That per-frame
            // rebuild — not the spring logic or the material blur, both already
            // fixed separately — is what was still reading as "laggy" during an
            // actual resize.
            SheetChrome(detent: $detent, height: geo.size.height, content: content())
        }
        .ignoresSafeArea()
    }
}

/// Owns everything that changes during an active drag. Isolated from
/// `BottomSheet` itself so high-frequency updates here never force `content`
/// (handed down as an already-built value, not a closure) to reconstruct.
///
/// The sheet height is tracked in a plain `@State`, not `@GestureState`. A
/// `@GestureState` value snaps back to its initial value the instant the
/// gesture ends, and that snap only picks up the surrounding `.animation(value:)`
/// if the *other* watched value (here, `detent`) actually changes — so a small
/// drag that settles back onto the same detent used to jump-cut instead of
/// animating. Driving `liveHeight` directly and always wrapping the settle in
/// an explicit `withAnimation` fixes that regardless of whether the detent changes.
private struct SheetChrome<Content: View>: View {
    @Binding var detent: SheetDetent
    let height: CGFloat
    let content: Content

    @State private var liveHeight: CGFloat?
    @State private var dragBaseline: CGFloat?

    private let snapAnimation = Animation.interpolatingSpring(stiffness: 320, damping: 32)

    var body: some View {
        let h = height
        let visible = liveHeight ?? (h * detent.fraction)

        VStack(spacing: 0) {
            grabber
                .contentShape(Rectangle())
                .gesture(dragGesture(height: h, currentVisible: visible))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .frame(height: h, alignment: .top)
        // `.regularMaterial` does live Gaussian blur/vibrancy sampling of
        // whatever's behind it — here, the map. Swap to a cheap static alpha
        // blend (no live sampling) while actively dragging, restore the real
        // material once settled.
        .background(
            dragBaseline != nil
                ? AnyShapeStyle(Color(.systemBackground).opacity(0.92))
                : AnyShapeStyle(.regularMaterial),
            in: sheetShape
        )
        .overlay(alignment: .top) { sheetShape.stroke(Color(.separator).opacity(0.5), lineWidth: 0.5).frame(height: h) }
        .offset(y: h - visible)
        .onAppear { liveHeight = h * detent.fraction }
        .onChange(of: detent) { _, newValue in
            guard dragBaseline == nil else { return }   // don't fight an active drag
            withAnimation(snapAnimation) { liveHeight = h * newValue.fraction }
        }
    }

    private func dragGesture(height h: CGFloat, currentVisible: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let base = dragBaseline ?? currentVisible
                if dragBaseline == nil { dragBaseline = base }
                liveHeight = min(h * 0.985, max(h * 0.08, base - value.translation.height))
            }
            .onEnded { value in
                let base = dragBaseline ?? currentVisible
                dragBaseline = nil
                let projected = min(h * 0.985, max(h * 0.08, base - value.predictedEndTranslation.height))
                let nearest = SheetDetent.allCases.min {
                    abs($0.fraction * h - projected) < abs($1.fraction * h - projected)
                } ?? detent
                // Exactly one path animates the settle, never both: if the detent
                // is actually changing, `.onChange(of: detent)` below does it; if
                // it's staying the same (a short drag that springs back), that
                // onChange never fires, so animate right here instead. Previously
                // both could fire — the same spring restarting a frame apart on
                // literally every release, which is a real source of visible stutter.
                if nearest == detent {
                    withAnimation(snapAnimation) { liveHeight = h * nearest.fraction }
                } else {
                    detent = nearest
                }
            }
    }

    private var sheetShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: ArcTheme.sheetCorner, topTrailingRadius: ArcTheme.sheetCorner)
    }

    /// 50pt tall — Apple's HIG minimum touch target is 44pt; the old 32pt zone
    /// was genuinely below that, so a finger not pixel-perfectly on the 5pt
    /// visual capsule would just miss it and nothing would happen, which reads
    /// as "unresponsive"/"buggy" even though the drag logic itself was fine.
    private var grabber: some View {
        Capsule().fill(Color(.tertiaryLabel))
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .contentShape(Rectangle())
            .background(.clear)
    }
}
