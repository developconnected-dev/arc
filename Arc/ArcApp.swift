import SwiftUI
import SwiftData
import BackgroundTasks

@main
struct ArcApp: App {
    @StateObject private var tracker = FlightTracker.shared
    let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(for: Flight.self, Airport.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ArcRootView()
                .onAppear {
                    if !DemoSeed.suppressPrompts {
                        ArcNotifications.requestPermission()
                    }
                    NetworkMonitor.shared.start()
                    registerBackgroundRefresh()

                    // Start the background Live Activity updater at app level
                    // This runs independently of views and survives backgrounding
                    BackgroundFlightUpdater.shared.start(modelContainer: modelContainer)
                }
        }
        .modelContainer(modelContainer)
    }

    private func registerBackgroundRefresh() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.arc.flighttracker.refresh",
            using: nil
        ) { task in
            guard let bgTask = task as? BGAppRefreshTask else { return }
            bgTask.expirationHandler = { bgTask.setTaskCompleted(success: false) }

            // When iOS wakes us for background refresh, push Live Activity updates
            Task { @MainActor in
                let context = ModelContext(self.modelContainer)
                let descriptor = FetchDescriptor<Flight>()
                if let flights = try? context.fetch(descriptor) {
                    await FlightTracker.shared.burstUpdate(flights: flights, modelContext: context)
                }
            }

            scheduleBackgroundRefresh()
            bgTask.setTaskCompleted(success: true)
        }
        scheduleBackgroundRefresh()
    }

    private func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "com.arc.flighttracker.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
