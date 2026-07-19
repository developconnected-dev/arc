import SwiftUI
import SwiftData

@main
struct ArcApp: App {
    @StateObject private var tracker = FlightTracker.shared

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .onAppear {
                    ArcNotifications.requestPermission()
                }
        }
        .modelContainer(for: [Flight.self, Airport.self])
    }
}
