import Foundation
import Network

/// Monitors network connectivity and triggers burst updates when WiFi reconnects mid-flight.
/// This is especially useful for in-flight WiFi — when the user gets internet back at 35,000ft,
/// Arc immediately fetches fresh delay/ETA/arrival gate data instead of waiting for the next poll.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published var isConnected = true
    @Published var isExpensive = false   // cellular
    @Published var isWiFi = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "arc.network.monitor")
    private var wasDisconnected = false

    /// Called when WiFi reconnects after being offline (e.g. in-flight WiFi comes on)
    var onReconnect: (() -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let connected = path.status == .satisfied
                let wifi = path.usesInterfaceType(.wifi)

                // Detect reconnection after being offline
                if connected && self.wasDisconnected {
                    self.onReconnect?()
                }

                self.wasDisconnected = !connected
                self.isConnected = connected
                self.isExpensive = path.isExpensive
                self.isWiFi = wifi
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
