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
/// Deliberately the simplest version of this gesture that's still correct —
/// no spring, no implicit animation in the drag, snapping on release is an
/// instant reassignment. (A detent set programmatically — see `onChange` —
/// is the one move that animates, on the morph spring.) This is a diagnostic as much as a design choice:
/// after three rounds of fixes (double-animation-trigger, material cost,
/// .local-coordinate-space feedback) still left dragging feeling like it
/// jumps, animation logic itself is the next thing to rule out by removing
/// it completely rather than reasoning about it further. `liveHeight` is
/// plain `@State`, not `@GestureState`, only because `@GestureState` resets
/// to its initial value the instant the gesture ends and there's no
/// animation here to smooth that transition over anymore anyway — a plain
/// `@State` that onEnded sets directly is the more direct match for "no
/// animation" than layering one on top of `@GestureState`'s own reset.
private struct SheetChrome<Content: View>: View {
    @Binding var detent: SheetDetent
    let height: CGFloat
    let content: Content

    @State private var liveHeight: CGFloat?
    @State private var dragBaseline: CGFloat?

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
            // A drag's snap already set liveHeight before assigning detent,
            // so this is a no-op for it. A PROGRAMMATIC detent — a detail
            // opening, a gate view lowering the sheet — is the one that
            // moves here, and it rides the morph spring so the sheet rises
            // with the elements rather than jumping ahead of them.
            liveHeight = h * newValue.fraction
        }
        // The spring for a programmatic detent lives on the view, where the
        // change happens: an animation opened by the caller never reaches
        // this tree through the tab controller's hosting boundary. A drag
        // bypasses it — `dragBaseline` is set for the finger's whole travel,
        // and the snap on release disables animation on its transaction.
        .animation(dragBaseline == nil ? ArcTheme.morph : nil, value: liveHeight)
    }

    private func dragGesture(height h: CGFloat, currentVisible: CGFloat) -> some Gesture {
        // .global, not the default .local: this gesture sits on the grabber,
        // which is itself repositioned every frame by the offset this same
        // gesture drives (offset depends on liveHeight, which onChanged just
        // set). With .local, translation is measured against the grabber's
        // own (moving) coordinate frame, so any lag between "how far the
        // view actually moved" and "how far the finger moved" — e.g. right
        // at the small/large clamp, where the view stops but the finger
        // keeps going — feeds back into the next translation reading and
        // reads as the sheet jumping/oscillating instead of tracking the
        // finger smoothly. .global measures against a frame that never
        // moves, which breaks the loop entirely.
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                // dragBaseline is cached on the *first* onChanged of this
                // drag and reused for every subsequent one — currentVisible
                // is only a fallback for that first call. Using currentVisible
                // directly on every call instead would make `base` itself a
                // moving target (it's re-derived from liveHeight, which this
                // same handler just changed), double-counting movement.
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
                var snap = Transaction()
                snap.disablesAnimations = true
                withTransaction(snap) {
                    liveHeight = h * nearest.fraction   // instant, no animation
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
