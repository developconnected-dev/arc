import SwiftUI
import WidgetKit

/// Arc's intelligence voice on WidgetKit surfaces — the Siri palette from
/// ArcTheme.SiriGlow (that file is app-target only; keep the two in sync).
///
/// Widgets can't animate: no TimelineView, no shaders, no repeating effects.
/// The "living" quality comes from the same system-animated primitive as the
/// flight-path reveal — a linear ProgressView(timerInterval:) stretched into
/// a mask sweeps the gradient across the text over the state's own lifetime,
/// offline, with the app dead. The motion IS the wait: every glance at the
/// lock screen catches it a little further along, and when the wait ends the
/// state (and its shimmer) is replaced by a confirmed one.
struct IntelligenceShimmerText: View {
    let text: String
    let font: Font
    /// The window the gradient sweeps across — typically the hedging state's
    /// own lifetime. Fully swept (a completed interval) is a valid resting
    /// look: the full gradient, no motion.
    let sweep: ClosedRange<Date>

    private static let palette: [Color] = [
        Color(red: 0.35, green: 0.55, blue: 1.00),
        Color(red: 0.70, green: 0.35, blue: 1.00),
        Color(red: 1.00, green: 0.35, blue: 0.62),
        Color(red: 1.00, green: 0.62, blue: 0.30),
    ]

    static var gradient: LinearGradient {
        LinearGradient(colors: palette, startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Base: quiet secondary text — what the sheen hasn't reached yet.
            Text(text).font(font).foregroundStyle(.secondary)
            // Sheen: the gradient copy, revealed left→right by the timer mask
            // (only the mask's alpha matters — stretch the ~4pt bar to cover
            // the text height, same trick as FlightPathProgress).
            Text(text).font(font)
                .foregroundStyle(Self.gradient)
                .mask {
                    GeometryReader { geo in
                        ProgressView(
                            timerInterval: sweep,
                            countsDown: false,
                            label: { EmptyView() },
                            currentValueLabel: { EmptyView() }
                        )
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .scaleEffect(x: 1, y: geo.size.height * 3, anchor: .center)
                    }
                }
        }
    }
}
