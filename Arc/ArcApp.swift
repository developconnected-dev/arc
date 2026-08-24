import SwiftUI
import SwiftData
import BackgroundTasks
import UserNotifications

@main
struct ArcApp: App {
    /// Owns the device's APNs registration. An adaptor rather than a call in
    /// `onAppear`, because `didRegisterForRemoteNotifications` is delivered to
    /// the application delegate and nowhere else.
    @UIApplicationDelegateAdaptor(RemotePush.self) private var remotePush
    @StateObject private var tracker = FlightTracker.shared
    @Environment(\.scenePhase) private var scenePhase
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
                    UNUserNotificationCenter.current().delegate = ForegroundNotificationDelegate.shared
                    if !DemoSeed.suppressPrompts {
                        ArcNotifications.requestPermission()
                    }
                    NetworkMonitor.shared.start()
                    LiveActivityPushSync.start(modelContainer: modelContainer)

                    // Start the background Live Activity updater at app level
                    // This runs independently of views and survives backgrounding
                    BackgroundFlightUpdater.shared.start(modelContainer: modelContainer)
                }
        }
        .modelContainer(modelContainer)
        // The SwiftUI scene modifier — not BGTaskScheduler.register — because
        // registration must happen before the app finishes launching. The
        // previous hand-rolled version registered inside onAppear (too late,
        // so iOS would never fire the task) and also called setTaskCompleted
        // immediately after *spawning* the refresh work rather than after
        // finishing it, so iOS could suspend the process mid-fetch. This
        // modifier registers at scene-build time and awaits the actual work.
        .backgroundTask(.appRefresh("com.arc.flighttracker.refresh")) { [modelContainer] in
            await Self.scheduleBackgroundRefresh()   // chain the next wakeup first
            await Self.runBackgroundRefresh(container: modelContainer)
        }
        .onChange(of: scenePhase) { _, phase in
            // (Re)arm a refresh request whenever we leave the foreground —
            // iOS only honors submissions from apps it has seen active recently.
            if phase == .background { Self.scheduleBackgroundRefresh() }
            // Live Activity pushes keep arriving while the app is suspended,
            // and `contentUpdates` cannot replay them. Whatever landed in the
            // meantime is read back here — the only path by which fresh facts
            // reach the model on a plane, where the push channel is up but
            // nothing can reach our backend.
            if phase == .active { LiveActivityPushSync.reconcile() }
        }
    }

    @MainActor
    private static func runBackgroundRefresh(container: ModelContainer) async {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Flight>()
        guard let flights = try? context.fetch(descriptor) else { return }
        await FlightTracker.shared.burstUpdate(flights: flights, modelContext: context)
        // The whole point of the background window is fresh data while the
        // app stays closed — push it to the home-screen widget too.
        WidgetSync.sync(flights: flights)
        // Friend alerts + friend Live Activities ride the same background
        // window (refresh internally diffs against the persisted baseline).
        await FriendsStore.shared.refresh()
    }

    private static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "com.arc.flighttracker.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// Shows notification banners while the app is FOREGROUND too — friend
/// takeoffs/landings would otherwise vanish silently whenever the app
/// happens to be open when its refresh discovers them.
final class ForegroundNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = ForegroundNotificationDelegate()
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// Tapping an alert opens the flight it was about. The destination is read
    /// off `userInfo` here (a dictionary of `Any` can't cross to the main actor)
    /// and parked, so it survives a cold launch where the root view — and
    /// SwiftData — aren't ready yet.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let destination = ArcDeepLink.destination(fromNotificationUserInfo: info) else { return }
        await MainActor.run {
            PendingFlightOpen.destination = destination
            NotificationCenter.default.post(name: .arcOpenFlight, object: nil)
        }
    }
}
