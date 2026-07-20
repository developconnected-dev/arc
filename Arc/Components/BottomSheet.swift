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
///
/// The sheet height is tracked in a plain `@State`, not `@GestureState`. A
/// `@GestureState` value snaps back to its initial value the instant the
/// gesture ends, and that snap only picks up the surrounding `.animation(value:)`
/// if the *other* watched value (here, `detent`) actually changes — so a small
/// drag that settles back onto the same detent used to jump-cut instead of
/// animating. Driving `liveHeight` directly and always wrapping the settle in
/// an explicit `withAnimation` fixes that regardless of whether the detent changes.
struct BottomSheet<Content: View>: View {
    @Binding var detent: SheetDetent
    @ViewBuilder var content: () -> Content

    @State private var liveHeight: CGFloat?
    @State private var dragBaseline: CGFloat?

    private let snapAnimation = Animation.interpolatingSpring(stiffness: 320, damping: 32)

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let visible = liveHeight ?? (h * detent.fraction)

            VStack(spacing: 0) {
                grabber
                    .contentShape(Rectangle())
                    .gesture(dragGesture(height: h, currentVisible: visible))
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity)
            .frame(height: h, alignment: .top)
            .background(.regularMaterial, in: sheetShape)
            .overlay(alignment: .top) { sheetShape.stroke(Color(.separator).opacity(0.5), lineWidth: 0.5).frame(height: h) }
            .offset(y: h - visible)
            .onAppear { liveHeight = h * detent.fraction }
            .onChange(of: detent) { _, newValue in
                guard dragBaseline == nil else { return }   // don't fight an active drag
                withAnimation(snapAnimation) { liveHeight = h * newValue.fraction }
            }
        }
        .ignoresSafeArea()
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
                withAnimation(snapAnimation) { liveHeight = h * nearest.fraction }
                detent = nearest
            }
    }

    private var sheetShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: ArcTheme.sheetCorner, topTrailingRadius: ArcTheme.sheetCorner)
    }

    private var grabber: some View {
        Capsule().fill(Color(.tertiaryLabel))
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .padding(.top, 6)
            .background(.clear)
    }
}
