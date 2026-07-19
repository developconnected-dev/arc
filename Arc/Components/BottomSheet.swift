import SwiftUI

/// A draggable, multi-detent bottom sheet that sits in a ZStack over the map,
/// so a floating tab bar can be layered above it. Detents are fractions of height.
struct BottomSheet<Content: View>: View {
    enum Detent: CaseIterable { case small, medium, large
        var fraction: CGFloat { switch self { case .small: 0.30; case .medium: 0.58; case .large: 0.92 } }
    }

    @Binding var detent: Detent
    @ViewBuilder var content: () -> Content
    @GestureState private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let target = h * detent.fraction
            let offset = max(h * 0.08, min(h * 0.92, target - drag))

            VStack(spacing: 0) {
                Capsule().fill(Color(.tertiaryLabel))
                    .frame(width: 36, height: 5).padding(.top, 8).padding(.bottom, 6)
                content()
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: h)
            .background(.regularMaterial,
                        in: UnevenRoundedRectangle(topLeadingRadius: ArcTheme.sheetCorner,
                                                   topTrailingRadius: ArcTheme.sheetCorner))
            .overlay(alignment: .top) {
                UnevenRoundedRectangle(topLeadingRadius: ArcTheme.sheetCorner,
                                       topTrailingRadius: ArcTheme.sheetCorner)
                    .stroke(Color(.separator).opacity(0.5), lineWidth: 0.5)
                    .frame(height: h)
            }
            .offset(y: h - offset)
            .gesture(
                DragGesture()
                    .updating($drag) { value, state, _ in state = -value.translation.height }
                    .onEnded { value in snap(to: value.predictedEndTranslation.height, height: h) }
            )
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: detent)
        }
        .ignoresSafeArea()
    }

    private func snap(to predicted: CGFloat, height: CGFloat) {
        let current = height * detent.fraction - predicted
        let nearest = Detent.allCases.min {
            abs($0.fraction * height - current) < abs($1.fraction * height - current)
        } ?? .medium
        detent = nearest
    }
}
