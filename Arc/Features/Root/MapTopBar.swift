import SwiftUI

/// My Trips' top row on the map, just under the Dynamic Island: the avatar,
/// a centre pill that says "My Trips" — or, while a detail shows a flight
/// with a fresh position, its speed and altitude — and share + "...".
/// The pill never touches its neighbours (`TopPillPlacement`).
struct MapTopBar: View {
    let layout: MyTripsLayout
    @Bindable var controller: MapController
    /// The flight a detail is showing, once its glide has landed.
    let liveFlight: Flight?
    let shareFlight: Flight?

    /// The capsule's pieces, shared by its layout and the width the pill avoids.
    private static let iconWidth: CGFloat = 42
    private static let capsuleInset: CGFloat = 4

    @State private var showSettings = false
    @State private var sharing: Flight?
    /// The last readout shown, so a closing detail's numbers can fade out
    /// in place instead of vanishing with the text they measured.
    @State private var lastReadout: String?

    var body: some View {
        // The readout expires by the clock, not only when data changes.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let readout = liveFlight.flatMap {
                LiveReadout.text(speed: $0.liveSpeed, altitude: $0.liveAltitude,
                                 updatedAt: $0.liveUpdatedAt, now: context.date)
            }
            // Worked out, not measured: a measured width lags one layout pass behind
            // the share button appearing, and the capsule would jump for a frame.
            let capsuleWidth: CGFloat = (shareFlight == nil ? 1 : 2) * Self.iconWidth + 2 * Self.capsuleInset
            let leadingEdge = MyTripsLayout.margin + MyTripsLayout.control
            let trailingEdge = layout.size.width - MyTripsLayout.margin - capsuleWidth

            ZStack(alignment: .topLeading) {
                avatar
                    .offset(x: MyTripsLayout.margin, y: layout.topBarY)
                pill(readout, leadingEdge: leadingEdge, trailingEdge: trailingEdge)
                    .frame(width: layout.size.width, height: 36)
                    .offset(y: layout.topBarY + 4)
                trailingCapsule
                    .offset(x: layout.size.width - MyTripsLayout.margin - capsuleWidth, y: layout.topBarY)
            }
            .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
            .animation(.smooth(duration: 0.3), value: readout)
            .animation(.smooth(duration: 0.3), value: shareFlight?.id)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(item: $sharing) { ShareFlightSheet(flight: $0) }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-openSettings") { showSettings = true }
        }
    }

    private var avatar: some View {
        Button { showSettings = true } label: {
            ProfileButtonIcon(size: 34)
                .frame(width: MyTripsLayout.control, height: MyTripsLayout.control)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }

    /// Both titles stay in the tree and crossfade; the layout sizes the
    /// capsule from the one showing in the same pass the text changes, so
    /// the glass widens or narrows with the crossfade, never a frame after
    /// it, and neither title is squeezed by the other's width mid-change.
    private func pill(_ readout: String?, leadingEdge: CGFloat, trailingEdge: CGFloat) -> some View {
        let shows = readout != nil
        return TopPillLayout(showsReadout: shows, leadingEdge: leadingEdge, trailingEdge: trailingEdge) {
            Color.clear
                .glassEffect(.regular, in: .capsule)
                .accessibilityElement()
                .accessibilityLabel(readout ?? "My Trips")
                .accessibilityAddTraits(.isStaticText)
                .accessibilityIdentifier("map-top-title")
            Text("My Trips")
                .font(.system(size: 17, weight: .semibold))
                .pillText()
                .opacity(shows ? 0 : 1)
            HStack(spacing: 6) {
                Circle().fill(ArcTheme.onTime).frame(width: 8, height: 8)
                Text(readout ?? lastReadout ?? "")
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .font(.system(size: 15, weight: .semibold))
            .pillText()
            .opacity(shows ? 1 : 0)
        }
        .onChange(of: readout, initial: true) { _, new in if let new { lastReadout = new } }
    }

    private var trailingCapsule: some View {
        HStack(spacing: 0) {
            if let shareFlight {
                Button { sharing = shareFlight } label: { icon("square.and.arrow.up") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Share \(shareFlight.flightNumberSpaced)")
                    .transition(.opacity)
            }
            Menu {
                Picker("Map style", selection: $controller.style) {
                    Label("Standard", systemImage: "map").tag(MapController.MapStyleKind.standard)
                    Label("Satellite", systemImage: "globe.europe.africa.fill").tag(MapController.MapStyleKind.hybrid)
                }
                Toggle(isOn: Binding(get: { controller.showWeatherHazards },
                                     set: { on in withAnimation(.easeInOut) { controller.showWeatherHazards = on } })) {
                    Label("Weather hazards", systemImage: "cloud.bolt.rain")
                }
            } label: {
                icon("ellipsis.circle")
                    // Only while the layer is off AND would show something
                    // on a route — an invitation, not a decoration.
                    .overlay(alignment: .topTrailing) {
                        if controller.hazardsTouchRoutes && !controller.showWeatherHazards {
                            Circle().fill(Color.orange)
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                                .padding(9)
                        }
                    }
            }
            .accessibilityLabel("Map options")
        }
        .padding(.horizontal, Self.capsuleInset)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: Self.iconWidth, height: MyTripsLayout.control)
            .contentShape(Rectangle())
    }
}

/// The centre pill's capsule and its two titles, sized and placed in one
/// pass: the capsule takes the natural width of the title showing, capped
/// to the room between the corner controls, at the x `TopPillPlacement`
/// gives it. Each title keeps its own capped width, so the one fading out
/// is never squeezed into the other's capsule.
private struct TopPillLayout: Layout {
    var showsReadout: Bool
    var leadingEdge: CGFloat
    var trailingEdge: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: trailingEdge, height: 36))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let room = TopPillPlacement.maxWidth(leadingEdge: leadingEdge, trailingEdge: trailingEdge)
        let title = min(subviews[1].sizeThatFits(.unspecified).width, room)
        let readout = min(subviews[2].sizeThatFits(.unspecified).width, room)
        let width = showsReadout ? readout : title
        let centre = CGPoint(x: bounds.minX + TopPillPlacement.centreX(pillWidth: width, width: bounds.width,
                                                                        leadingEdge: leadingEdge, trailingEdge: trailingEdge),
                             y: bounds.midY)
        subviews[0].place(at: centre, anchor: .center, proposal: ProposedViewSize(width: width, height: bounds.height))
        subviews[1].place(at: centre, anchor: .center, proposal: ProposedViewSize(width: title, height: bounds.height))
        subviews[2].place(at: centre, anchor: .center, proposal: ProposedViewSize(width: readout, height: bounds.height))
    }
}

private extension View {
    func pillText() -> some View {
        foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 16)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

/// Fits the map back to what the surface is about: all trips on the list,
/// the opened trip in a detail.
struct RecenterButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "location.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: MyTripsLayout.control, height: MyTripsLayout.control)
                // Without it the button's hit area is the glyph's own shape:
                // a tap inside the glass circle but off the arrow did nothing
                // at all (found while wiring the bell beside it).
                .contentShape(.rect)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recenter map")
        .accessibilityIdentifier("map-recenter")
    }
}
