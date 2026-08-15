import SwiftUI

/// Flighty-parity design tokens. Built on semantic system colors + materials so
/// light/dark tracks the system automatically.
enum ArcTheme {
    // Brand & Status
    static let brand  = Color(red: 0.38, green: 0.45, blue: 1.00)   // #6173FF Premium Indigo
    static let onTime = Color(red: 0.20, green: 0.78, blue: 0.35)   // #34C759
    static let late   = Color(red: 1.00, green: 0.23, blue: 0.19)   // #FF3B30
    static let action = Color(red: 0.04, green: 0.52, blue: 1.00)   // #0A84FF
    static let gate   = Color(red: 1.00, green: 0.80, blue: 0.00)   // #FFCC00
    /// Map route arcs specifically — brighter/lighter than `action` on purpose,
    /// so the great-circle line reads clearly against both map styles instead
    /// of blending into standard UI blue.
    static let routeLine = Color(red: 0.30, green: 0.69, blue: 1.00)   // #4DB0FF
    /// Past flights' routes: same hue family, darker and muted — history
    /// recedes, upcoming/current flights glow (Flighty's visual language).
    static let routeLinePast = Color(red: 0.18, green: 0.38, blue: 0.58).opacity(0.65)
    /// Sea legs: a teal wake, dotted, on a rhumb line — deliberately not the
    /// sky-blue arc, so a sailing is never mistaken for a flight at a glance.
    static let seaLine = Color(red: 0.05, green: 0.68, blue: 0.72)   // #0DADB8 — deeper teal, reads on blue water
    static let seaLinePast = Color(red: 0.14, green: 0.42, blue: 0.45).opacity(0.65)

    static func timeColor(late: Bool) -> Color { late ? Self.late : Self.onTime }

    /// The one visual voice for what Arc INFERS itself — delay predictions,
    /// AI-read searches — as opposed to data the airline reported. Sparkles
    /// plus this coral→magenta ramp, nothing louder, and used sparingly:
    /// the marker only means something while it's rare.
    static let smartGradient = LinearGradient(
        colors: [Color(red: 1.00, green: 0.48, blue: 0.30),
                 Color(red: 0.83, green: 0.27, blue: 0.75)],
        startPoint: .leading, endPoint: .trailing)

    // Type scale (system SF Pro)
    static let screenTitle = Font.system(size: 34, weight: .heavy)
    static let sheetTitle  = Font.system(size: 22, weight: .bold)
    static let bigTime     = Font.system(size: 40, weight: .regular)
    static let iata        = Font.system(size: 16, weight: .bold)
    static let cityPair    = Font.system(size: 22, weight: .semibold)
    static let bodyEmph    = Font.system(size: 15, weight: .semibold)
    static let caption     = Font.system(size: 13, weight: .regular)
    static let captionEmph = Font.system(size: 13, weight: .semibold)
    static let tag         = Font.system(size: 13, weight: .medium)
    static let countdownNum = Font.system(size: 30, weight: .heavy)
    static let countdownUnit = Font.system(size: 11, weight: .bold)

    // Metrics
    static let sheetCorner: CGFloat = 22
    static let cardCorner: CGFloat = 14
    static let gatePillCorner: CGFloat = 8
    static let screenPad: CGFloat = 20
}

/// Yellow gate pill used in flight detail (`↗ C8`).
struct GatePill: View {
    let arrow: String   // "arrow.up.right" or "arrow.down.right"
    let gate: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: arrow).font(.system(size: 11, weight: .bold))
            Text(gate).font(.system(size: 17, weight: .bold))
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(ArcTheme.gate, in: RoundedRectangle(cornerRadius: ArcTheme.gatePillCorner))
    }
}

/// "✦ Arc predicts ~32m late" — the badge for Arc's own inferences.
/// Sparkles + the smart gradient and nothing else; if a number came from the
/// airline, it never wears this. A slow shimmer sweeps across on a long,
/// regular cadence — a quiet pulse, not a spinner: the pause between sweeps
/// is what keeps it feeling considered rather than busy.
struct SmartLabel: View {
    let text: String
    var size: CGFloat = 14
    @State private var sweeping = false

    var body: some View {
        label
            .overlay {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.85), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.55)
                        .offset(x: sweeping ? geo.size.width + 12 : -geo.size.width * 0.55 - 12)
                }
                .mask(label)
                .allowsHitTesting(false)
            }
            .task {
                // Both rest positions sit outside the mask, so the un-animated
                // reset between sweeps is invisible.
                try? await Task.sleep(for: .seconds(0.4))
                while !Task.isCancelled {
                    withAnimation(.easeInOut(duration: 1.8)) { sweeping = true }
                    try? await Task.sleep(for: .seconds(2.0))
                    sweeping = false
                    try? await Task.sleep(for: .seconds(6.0))
                }
            }
            // A changed prediction sweeps IMMEDIATELY — the shimmer is Arc
            // saying "I just re-thought this", not only an ambient pulse.
            .onChange(of: text) { _, _ in
                Task {
                    sweeping = false
                    try? await Task.sleep(for: .milliseconds(60))
                    withAnimation(.easeInOut(duration: 1.8)) { sweeping = true }
                }
            }
    }

    private var label: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles")
                .font(.system(size: size - 2, weight: .semibold))
            Text(text)
                .font(.system(size: size, weight: .bold))
        }
        .foregroundStyle(ArcTheme.smartGradient)
    }
}

/// The Apple-Intelligence edge treatment, honestly borrowed: the Siri palette
/// as an angular gradient stroked around a capsule, a blurred twin providing
/// the bloom, and a slowly rotating phase so the colors travel. At rest it
/// breathes quietly; `active` (the AI is reading) brightens and widens it.
struct SiriGlow: ViewModifier {
    var active: Bool

    private static let palette: [Color] = [
        Color(red: 0.35, green: 0.55, blue: 1.00),
        Color(red: 0.70, green: 0.35, blue: 1.00),
        Color(red: 1.00, green: 0.35, blue: 0.62),
        Color(red: 1.00, green: 0.62, blue: 0.30),
        Color(red: 0.35, green: 0.55, blue: 1.00),
    ]

    func body(content: Content) -> some View {
        content
            .overlay {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    // Siri speeds up when it's listening: slow color travel at
                    // rest, brisk while the AI reads.
                    let gradient = AngularGradient(
                        colors: Self.palette, center: .center,
                        angle: .degrees((t * (active ? 55 : 20)).truncatingRemainder(dividingBy: 360)))
                    let breathe = 0.5 + 0.5 * sin(t * 1.3)
                    ZStack {
                        // Wide bloom spilling OUTSIDE the bar — the light the
                        // earlier mask was clipping away; without it the glow
                        // reads as a faint colored border, not a glow.
                        Capsule().stroke(gradient, lineWidth: active ? 6 : 3.5)
                            .blur(radius: active ? 11 : 8)
                        // Tight halo hugging the edge.
                        Capsule().stroke(gradient, lineWidth: active ? 2.5 : 1.6)
                            .blur(radius: 1.5)
                        // The crisp line itself.
                        Capsule().strokeBorder(gradient, lineWidth: active ? 1.6 : 1.1)
                    }
                    .opacity(active ? 0.85 + 0.15 * breathe : 0.5 + 0.25 * breathe)
                }
                .allowsHitTesting(false)
            }
            .animation(.easeInOut(duration: 0.35), value: active)
    }
}

extension View {
    func siriGlow(active: Bool) -> some View { modifier(SiriGlow(active: active)) }
}
