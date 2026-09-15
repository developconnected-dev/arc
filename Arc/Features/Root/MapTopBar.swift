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
    @State private var pillIdeal: CGFloat = 96

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
            let maxWidth = TopPillPlacement.maxWidth(leadingEdge: leadingEdge, trailingEdge: trailingEdge)
            let width = min(pillIdeal, maxWidth)
            let centreX = TopPillPlacement.centreX(pillWidth: width, width: layout.size.width,
                                                   leadingEdge: leadingEdge, trailingEdge: trailingEdge)

            ZStack(alignment: .topLeading) {
                avatar
                    .offset(x: MyTripsLayout.margin, y: layout.topBarY)
                pill(readout)
                    .minimumScaleFactor(0.8)
                    .frame(width: width, height: 36)
                    .glassEffect(.regular, in: .capsule)
                    .background {
                        // The pill's natural width, measured off-screen so
                        // the visible copy can be capped without feeding back.
                        pill(readout).fixedSize().hidden()
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pillIdeal = $0 }
                    }
                    .offset(x: centreX - width / 2, y: layout.topBarY + 4)
                    .accessibilityIdentifier("map-top-title")
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

    @ViewBuilder
    private func pill(_ readout: String?) -> some View {
        Group {
            if let readout {
                HStack(spacing: 6) {
                    Circle().fill(ArcTheme.onTime).frame(width: 8, height: 8)
                    Text(readout)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .font(.system(size: 15, weight: .semibold))
                .transition(.opacity)
            } else {
                Text("My Trips")
                    .font(.system(size: 17, weight: .semibold))
                    .transition(.opacity)
            }
        }
        .foregroundStyle(.primary)
        .lineLimit(1)
        .padding(.horizontal, 16)
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
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recenter map")
        .accessibilityIdentifier("map-recenter")
    }
}
