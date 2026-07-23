import Foundation
import ActivityKit

/// Bridges ActivityKit's push tokens to the Worker so Live Activities can be
/// updated (and even started) server-side via APNs — the piece that makes the
/// lock screen genuinely live with the app closed, and the architecture
/// Flighty itself uses.
///
/// One observation point covers everything: `activityUpdates` yields every
/// newly started activity regardless of whether WE requested it locally or
/// the server started it via push-to-start, so LiveActivityManager needs no
/// registration logic of its own beyond requesting with `pushType: .token`.
@MainActor
enum LiveActivityPushSync {
    private static var started = false

    /// The APNs environment this build's tokens belong to. Xcode-run builds
    /// (DEBUG) get sandbox tokens; archived/TestFlight builds get production.
    /// The Worker routes each token to the matching APNs host.
    private static var apnsEnv: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    static func start() {
        guard !started else { return }
        started = true

        // Push-to-start token: lets the server START a Live Activity for an
        // upcoming flight even if the app hasn't been opened in days.
        Task {
            for await tokenData in Activity<FlightActivityAttributes>.pushToStartTokenUpdates {
                let body: [String: Any] = [
                    "token": hex(tokenData),
                    "type": "start",
                    "env": apnsEnv,
                ]
                guard let json = try? JSONSerialization.data(withJSONObject: body) else { continue }
                await FlightAPIClient.shared.registerLiveActivityToken(json)
            }
        }

        // Per-activity update tokens, for both locally- and remotely-started
        // activities. Tokens can rotate mid-flight, hence the inner loop.
        Task {
            for await activity in Activity<FlightActivityAttributes>.activityUpdates {
                observe(activity)
            }
        }

        // Activities that already existed before this launch (started in a
        // previous session) don't come through activityUpdates — pick them up
        // explicitly or their tokens would never re-register after a relaunch.
        for activity in Activity<FlightActivityAttributes>.activities {
            observe(activity)
        }
    }

    private static func observe(_ activity: Activity<FlightActivityAttributes>) {
        Task {
            for await tokenData in activity.pushTokenUpdates {
                let body = registrationBody(for: activity, token: hex(tokenData))
                guard let json = try? JSONSerialization.data(withJSONObject: body) else { continue }
                await FlightAPIClient.shared.registerLiveActivityToken(json)
            }
        }
        Task {
            for await state in activity.activityStateUpdates {
                if state == .ended || state == .dismissed {
                    if let token = activity.pushToken {
                        await FlightAPIClient.shared.unregisterLiveActivityToken(hex(token))
                    }
                }
            }
        }
    }

    /// Everything the Worker's cron needs to keep pushing without a database
    /// lookup: identity from the attributes, schedule from the content state.
    private static func registrationBody(for activity: Activity<FlightActivityAttributes>, token: String) -> [String: Any] {
        let attrs = activity.attributes
        let state = activity.content.state
        let iso = ISO8601DateFormatter()
        return [
            "token": token,
            "type": "update",
            "env": apnsEnv,
            "flight": [
                "flight_number": attrs.flightNumber,
                "departure_iata": attrs.departureIATA,
                "arrival_iata": attrs.arrivalIATA,
                "departure_city": attrs.departureCity,
                "arrival_city": attrs.arrivalCity,
                "airline": attrs.airline,
                "aircraft_type": attrs.aircraftType as Any,
                "seat": attrs.seat as Any,
                "scheduled_departure": iso.string(from: state.departureTime),
                "scheduled_arrival": iso.string(from: state.arrivalTime),
            ],
        ]
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
