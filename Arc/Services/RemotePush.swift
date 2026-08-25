import Foundation
import UIKit
import UserNotifications

/// The device's own APNs channel — the one that is not tied to a Live Activity.
///
/// Until this existed, every notification Arc sent was a LOCAL one, scheduled
/// on the device by `FlightTracker`. That means it could only ever fire while
/// the app was awake: the cron could know at 04:50 that a flight was cancelled
/// and have no way to say so. A Live Activity covers the last three hours
/// before departure (the Worker opens a card with push-to-start and its
/// updates carry alerts); everything earlier had no channel at all.
///
/// It also rides the same connection as iMessage, which is why airline
/// "free messaging" Wi-Fi carries it: a delay announced while the traveller is
/// already airborne on the previous leg still lands.
@MainActor
final class RemotePush: NSObject, UIApplicationDelegate {
    /// Set once APNs has handed us a token AND the Worker has accepted it.
    /// The local instant alerts consult this so the traveller does not hear
    /// the same gate change twice.
    ///
    /// `nonisolated` because those alerts are posted from wherever the tracker
    /// happens to notice the change; the storage underneath is UserDefaults,
    /// which is thread-safe.
    nonisolated static var isRegistered: Bool {
        UserDefaults.standard.bool(forKey: "remotePushRegistered")
    }

    private static func setRegistered(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: "remotePushRegistered")
    }

    private static var lastToken: String?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Asking APNs for a token is not the same as asking the USER for
        // permission — this is safe at launch, and the banner prompt is still
        // gated by ArcNotifications.requestPermission().
        application.registerForRemoteNotifications()
        // HERE, not in a SwiftUI `.onAppear`. UNUserNotificationCenter only
        // delivers the notification that LAUNCHED the app to a delegate that
        // was already assigned when launching finished — set it any later and
        // a cold-launch tap is delivered to nobody. That is why tapping a
        // friend's alert from a shut app opened the app on whatever it last
        // showed instead of the flight the alert named.
        UNUserNotificationCenter.current().delegate = ForegroundNotificationDelegate.shared
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Self.lastToken = token
        Task { await Self.register(token) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No token, no server-side alerts — the local ones must keep firing.
        Self.setRegistered(false)
    }

    /// Re-post the token whenever the owner changes. The Worker looks flights
    /// up BY owner, so a token registered before sign-in can never be sent
    /// anything, and a token left behind after sign-out would be sent the
    /// wrong person's news.
    static func ownerDidChange() {
        guard let token = lastToken else { return }
        Task { await register(token) }
    }

    static func signOut() async {
        setRegistered(false)
        guard let token = lastToken else { return }
        await FlightAPIClient.shared.unregisterDeviceToken(token)
    }

    private static func register(_ token: String) async {
        guard let userId = ArcSupabase.shared.currentUser?.id else {
            // Signed out: nothing to register against. The Worker looks flights
            // up BY owner and refuses an ownerless token, so there is nothing
            // to send until `ownerDidChange` brings us back here.
            setRegistered(false)
            return
        }
        // The signing profile, not the build configuration — see
        // `APNsEnvironment`. A Release build on a development profile holds a
        // sandbox token and used to report "production", so every push to it
        // was refused and the token dropped as dead.
        let env = APNsEnvironment.current
        guard let body = try? JSONSerialization.data(
            withJSONObject: ["token": token, "env": env, "user_id": userId]) else { return }
        setRegistered(await FlightAPIClient.shared.registerDeviceToken(body))
    }
}
