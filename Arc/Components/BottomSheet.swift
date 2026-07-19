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
    @GestureState private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let target = h * detent.fraction
            let visible = max(h * 0.10, min(h * 0.96, target - drag))

            VStack(spacing: 0) {
                grabber
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .updating($drag) { value, state, _ in state = -value.translation.height }
                            .onEnded { value in snap(to: value.predictedEndTranslation.height, height: h) }
                    )
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity)
            .frame(height: h, alignment: .top)
            .background(.regularMaterial, in: sheetShape)
            .overlay(alignment: .top) { sheetShape.stroke(Color(.separator).opacity(0.5), lineWidth: 0.5).frame(height: h) }
            .offset(y: h - visible)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: detent)
        }
        .ignoresSafeArea()
    }

    private var sheetShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: ArcTheme.sheetCorner, topTrailingRadius: ArcTheme.sheetCorner)
    }

    private var grabber: some View {
        Capsule().fill(Color(.tertiaryLabel))
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .padding(.top, 6)
            .background(.clear)
    }

    private func snap(to predicted: CGFloat, height: CGFloat) {
        let current = height * detent.fraction - predicted
        let nearest = SheetDetent.allCases.min {
            abs($0.fraction * height - current) < abs($1.fraction * height - current)
        } ?? .medium
        detent = nearest
    }
}
