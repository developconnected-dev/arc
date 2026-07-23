import Foundation
import ActivityKit

/// Manages Live Activities for active flights.
/// Shows flight progress on lock screen and Dynamic Island.
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var activeActivities: [String: Activity<FlightActivityAttributes>] = [:]

    private func makeState(for flight: Flight) async -> FlightActivityAttributes.ContentState {
        // Use actual departure if available, otherwise adjust scheduled by delay
        let depTime: Date
        if let actual = flight.actualDeparture {
            depTime = actual
        } else if flight.delayMinutes > 0 {
            depTime = flight.scheduledDeparture.addingTimeInterval(Double(flight.delayMinutes) * 60)
        } else {
            depTime = flight.scheduledDeparture
        }
        let boardingMinutes = Self.estimateBoardingMinutes(airline: flight.airlineICAO, duration: flight.duration)
        let boardingTime = depTime.addingTimeInterval(-Double(boardingMinutes) * 60)

        // Fetch security wait time while the user could still be landside.
        // ("delayed" was checked here before, but that string never occurs —
        // the Worker normalizes it to "scheduled". boarding/gateClosed are
        // real statuses where the wait is no longer actionable, so skip them.)
        var securityWait: Int? = nil
        if flight.statusRaw == "scheduled" {
            securityWait = try? await FlightAPIClient.shared.securityWaitTime(iata: flight.departureIATA)?.securityMinutes
        }

        return FlightActivityAttributes.ContentState(
            status: flight.statusRaw,
            departureTime: depTime,
            arrivalTime: flight.estimatedArrival ?? flight.scheduledArrival,
            boardingTime: boardingTime,
            securityWaitMinutes: securityWait,
            delayMinutes: flight.delayMinutes,
            departureGate: flight.departureGate,
            departureTerminal: flight.departureTerminal,
            arrivalGate: flight.arrivalGate,
            arrivalTerminal: flight.arrivalTerminal,
            baggageClaim: flight.baggageClaim,
            altitude: flight.liveAltitude.map { $0 * 3.281 },
            speed: flight.liveSpeed.map { $0 * 1.944 },
            heading: flight.liveHeading,
            progress: flight.progress
        )
    }

    func startActivity(for flight: Flight) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // Don't start a duplicate
        if let existing = Activity<FlightActivityAttributes>.activities.first(where: {
            $0.attributes.flightNumber == flight.flightNumber &&
            $0.attributes.departureIATA == flight.departureIATA &&
            $0.attributes.arrivalIATA == flight.arrivalIATA
        }) {
            activeActivities[flight.id.uuidString] = existing
            return
        }
        guard activeActivities[flight.id.uuidString] == nil else { return }

        let attributes = FlightActivityAttributes(
            flightNumber: flight.flightNumber,
            departureIATA: flight.departureIATA,
            arrivalIATA: flight.arrivalIATA,
            departureCity: flight.departureCity,
            arrivalCity: flight.arrivalCity,
            airline: flight.airline,
            aircraftType: flight.aircraftType,
            seat: flight.seat
        )

        do {
            // pushType .token: ActivityKit hands us an APNs token for this
            // activity, LiveActivityPushSync registers it with the Worker, and
            // the Worker's cron pushes updates server-side — the activity keeps
            // moving with the app fully closed. Local update()/end() below
            // still work exactly the same alongside push.
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: await makeState(for: flight), staleDate: Self.staleDate),
                pushType: .token
            )
            activeActivities[flight.id.uuidString] = activity
        } catch {
            print("[Arc] Failed to start Live Activity: \(error)")
        }
    }

    /// Without remote push, updates only flow while our process is alive —
    /// tell iOS when the content should be considered outdated so the system
    /// (and our own `isStale`-aware UI) can reflect that instead of showing
    /// a frozen state as if it were current.
    private static var staleDate: Date { .now.addingTimeInterval(20 * 60) }

    func updateActivity(for flight: Flight) async {
        // `activeActivities` is in-memory only. After an app relaunch
        // mid-flight, the tracker never calls startActivity for an
        // already-active flight (that path only runs pre-departure), so
        // without this reconciliation every update would silently no-op and
        // the Live Activity would stay frozen at its pre-relaunch state.
        if activeActivities[flight.id.uuidString] == nil {
            if let existing = Activity<FlightActivityAttributes>.activities.first(where: {
                $0.attributes.flightNumber == flight.flightNumber &&
                $0.attributes.departureIATA == flight.departureIATA &&
                $0.attributes.arrivalIATA == flight.arrivalIATA
            }) {
                activeActivities[flight.id.uuidString] = existing
            }
        }
        guard let activity = activeActivities[flight.id.uuidString] else { return }

        let content = ActivityContent(state: await makeState(for: flight), staleDate: Self.staleDate)
        nonisolated(unsafe) let act = activity
        await act.update(content)
    }

    func endActivity(for flight: Flight) async {
        guard let activity = activeActivities[flight.id.uuidString] else { return }
        let flightId = flight.id.uuidString

        let finalState = FlightActivityAttributes.ContentState(
            status: "landed",
            departureTime: flight.actualDeparture ?? flight.scheduledDeparture,
            arrivalTime: flight.actualArrival ?? flight.scheduledArrival,
            boardingTime: nil,
            securityWaitMinutes: nil,
            delayMinutes: flight.delayMinutes,
            departureGate: flight.departureGate,
            departureTerminal: flight.departureTerminal,
            arrivalGate: flight.arrivalGate,
            arrivalTerminal: flight.arrivalTerminal,
            baggageClaim: flight.baggageClaim,
            altitude: nil,
            speed: nil,
            heading: nil,
            progress: 1.0
        )

        let content = ActivityContent(state: finalState, staleDate: nil)
        nonisolated(unsafe) let act = activity
        await act.end(content, dismissalPolicy: .after(.now + 3600))
        activeActivities.removeValue(forKey: flightId)
    }

    // MARK: - Smart Boarding Time Estimates

    /// Estimates how many minutes before departure boarding starts,
    /// based on airline and flight duration.
    private static func estimateBoardingMinutes(airline: String, duration: TimeInterval) -> Int {
        let icao = airline.uppercased()
        let isLongHaul = duration > 5 * 3600  // >5 hours

        // Airline-specific boarding times (minutes before departure)
        let airlineDefaults: [String: (shortHaul: Int, longHaul: Int)] = [
            // Low-cost carriers — board early, strict cutoffs
            "RYR": (45, 45),   // Ryanair
            "EZY": (40, 45),   // easyJet
            "EZS": (40, 45),   // easyJet Switzerland
            "WZZ": (40, 45),   // Wizz Air
            "VLG": (40, 45),   // Vueling
            "NKS": (45, 45),   // Spirit
            "FFT": (45, 45),   // Frontier

            // European legacy carriers
            "SWR": (35, 50),   // Swiss
            "DLH": (35, 50),   // Lufthansa
            "AUA": (35, 45),   // Austrian
            "BEL": (35, 45),   // Brussels Airlines
            "AFR": (35, 50),   // Air France
            "KLM": (35, 50),   // KLM
            "BAW": (35, 55),   // British Airways
            "SAS": (35, 45),   // SAS
            "TAP": (35, 45),   // TAP Portugal
            "IBE": (35, 50),   // Iberia
            "AZA": (35, 45),   // ITA Airways
            "THY": (40, 50),   // Turkish Airlines
            "AEE": (35, 45),   // Aegean

            // Middle East / long-haul specialists
            "UAE": (40, 60),   // Emirates
            "ETD": (40, 55),   // Etihad
            "QTR": (40, 55),   // Qatar Airways
            "SAA": (40, 50),   // Saudia

            // US carriers
            "AAL": (30, 45),   // American
            "DAL": (30, 45),   // Delta
            "UAL": (30, 45),   // United
            "SWA": (35, 35),   // Southwest
            "JBU": (30, 40),   // JetBlue

            // Asian carriers
            "SIA": (35, 55),   // Singapore Airlines
            "CPA": (35, 50),   // Cathay Pacific
            "ANA": (35, 50),   // ANA
            "JAL": (35, 50),   // JAL
        ]

        if let times = airlineDefaults[icao] {
            return isLongHaul ? times.longHaul : times.shortHaul
        }

        // Fallback defaults
        return isLongHaul ? 50 : 35
    }
}
