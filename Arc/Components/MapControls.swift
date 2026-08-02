import SwiftUI

/// Flighty-style floating map controls: a vertical pill (map-style toggle +
/// weather) and a separate circular recenter button beneath it.
struct MapControls: View {
    @Bindable var controller: MapController
    var onRecenter: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 0) {
                controlButton(controller.style == .hybrid ? "map.fill" : "map", color: .primary) {
                    controller.style = controller.style == .hybrid ? .standard : .hybrid
                }
                Divider().frame(width: 28)
                controlButton(controller.showWeatherHazards ? "cloud.bolt.rain.fill" : "cloud.bolt",
                              color: controller.showWeatherHazards ? .orange : .primary) {
                    withAnimation(.easeInOut) {
                        controller.showWeatherHazards.toggle()
                    }
                }
                // Badge only while the layer is off AND would actually show
                // something on a route — an invitation, not a decoration.
                .overlay(alignment: .topTrailing) {
                    if controller.hazardsTouchRoutes && !controller.showWeatherHazards {
                        Circle().fill(Color.orange)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                            .padding(8)
                    }
                }
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(.separator).opacity(0.4), lineWidth: 0.5))

            Button(action: onRecenter) {
                Image(systemName: "location.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .overlay(Circle().stroke(Color(.separator).opacity(0.4), lineWidth: 0.5))
            }.buttonStyle(.plain)
        }
    }

    private func controlButton(_ icon: String, color: Color = .primary, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
        }.buttonStyle(.plain)
    }
}
