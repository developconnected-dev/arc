import Foundation
import Network

/// Monitors network connectivity and triggers burst updates when ANY
/// connectivity returns — cellular or WiFi. That interface-agnostic detail is
/// load-bearing: after landing, the FIRST connection back is almost always
/// mobile data (airplane mode off, LTE), and in-flight it's WiFi at 35,000ft.
/// Both must trigger the immediate belt/gate/delay refresh, so the check is
/// `path.status == .satisfied`, never `usesInterfaceType(.wifi)`.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published var isConnected = true
    @Published var isExpensive = false   // cellular
    @Published var isWiFi = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "arc.network.monitor")
    private var wasDisconnected = false

    /// Called when connectivity returns after being offline — any interface:
    /// mobile data after landing, or in-flight WiFi mid-air.
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
