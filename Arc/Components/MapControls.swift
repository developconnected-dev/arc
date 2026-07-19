import SwiftUI

/// Flighty-style floating map controls: a vertical pill (map-style toggle +
/// weather) and a separate circular recenter button beneath it.
struct MapControls: View {
    @Bindable var controller: MapController
    var onRecenter: () -> Void
    @State private var weatherOn = false

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 0) {
                controlButton(controller.style == .hybrid ? "map.fill" : "map") {
                    controller.style = controller.style == .hybrid ? .standard : .hybrid
                }
                Divider().frame(width: 28)
                controlButton(weatherOn ? "cloud.fill" : "cloud") { weatherOn.toggle() }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(.separator).opacity(0.4), lineWidth: 0.5))

            Button(action: onRecenter) {
                Image(systemName: "location.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().stroke(Color(.separator).opacity(0.4), lineWidth: 0.5))
            }.buttonStyle(.plain)
        }
    }

    private func controlButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
        }.buttonStyle(.plain)
    }
}
