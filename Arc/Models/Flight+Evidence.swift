import Foundation
import CoreLocation

/// The app's view of `DepartureEvidence` — assembled from what the tracker
/// has stored, so every screen asks the same question of the same facts.
extension Flight {

    /// Gate departure: the schedule plus whatever delay the airline admits.
    /// (`effectiveDeparture` prefers a confirmed take-off, which is the wrong
    /// anchor here — the taxi is measured from the gate, not from wheels-up.)
    var offBlock: Date {
        scheduledDeparture.addingTimeInterval(Double(max(0, delayMinutes)) * 60)
    }

    var departureEvidence: DepartureEvidence {
        DepartureEvidence(
            offBlock: offBlock,
            estimatedTakeoff: estimatedTakeoff,
            actualDeparture: actualDeparture,
            groundState: groundStateRaw,
            groundObservedAt: groundObservedAt,
            taxiStartedAt: taxiStartedAt,
            lastSeenOnGround: lastSeenOnGround,
            taxiPriorMinutes: taxiPriorMinutes ?? DepartureEvidence.defaultTaxiPrior,
            // Non-air legs have no ADS-B and no runway times; a train that is
            // late leaving is simply late, so the taxi machinery stays out of
            // their way and the clock decides as it always did.
            isLiveCovered: mode == .air ? (departureLiveCovered ?? true) : true)
    }

    /// The evidence, read through what the app already knows about the leg.
    ///
    /// A completed flight settles the question by itself — it landed, so it
    /// flew — and a cancelled one never faces it. And a source that calls a
    /// leg active *before* its gate time is reporting an early departure:
    /// a trusted status ahead of the clock wins here exactly as it does in
    /// the widget's own phase.
    var departurePhase: DeparturePhase {
        switch status {
        case .landed, .diverted: return .airborne
        case .cancelled: return .beforeDeparture
        default: break
        }
        let phase = departureEvidence.phase(at: .now)
        if isActive, phase == .beforeDeparture { return .airborne }
        return phase
    }

    /// When Arc expects the wheels to leave the ground — what the widget's
    /// timeline and the Live Activity's staleDate are scheduled against.
    var expectedWheelsUp: Date { departureEvidence.expectedWheelsUp }

    /// How long the aircraft has been rolling, when something has seen it.
    var taxiElapsed: TimeInterval? {
        guard case .taxiing(let since) = departurePhase, let since else { return nil }
        return max(0, Date.now.timeIntervalSince(since))
    }

    /// Record what one ADS-B sample says. Returns true when this sighting is
    /// the take-off — the caller flips status and tells the other surfaces.
    @discardableResult
    func recordGroundSample(onGround: Bool, velocity: Double, altitude: Double, at now: Date = .now) -> Bool {
        let state = GroundState.classify(onGround: onGround, velocity: velocity, altitude: altitude)
        guard state != .unknown else { return false }
        groundStateRaw = state.rawValue
        groundObservedAt = now
        switch state {
        case .taxiing:
            if taxiStartedAt == nil { taxiStartedAt = now }
            lastSeenOnGround = now
        case .atGate:
            lastSeenOnGround = now
        case .airborne:
            // The aircraft is off the ground and something watched it happen.
            // Only claim the moment as the take-off if nobody better already
            // has — a provider's runway time is more precise than "the first
            // sample in which it was already flying".
            if actualDeparture == nil {
                actualDeparture = now
                return true
            }
        case .unknown:
            break
        }
        return false
    }

    /// How far from the arrival airport's reference point an aircraft on the
    /// ground still counts as "at" it — a hub's runways and stands span
    /// several kilometres from the point the provider calls the airport.
    static let landingRadiusKm: Double = 8

    /// Record what one sample says about the OTHER end of the flight, from
    /// the same evidence that confirms the first: an aircraft seen on the
    /// ground at its destination, after it left, has landed. A status string
    /// saying "Arrived" can lag touchdown by an hour, and until now nothing
    /// else ever confirmed a landing — every surface kept counting down to an
    /// arrival that had already happened. Returns true when this sighting is
    /// the landing — the caller tells the other surfaces.
    ///
    /// Guards: the sighting must be fresh (a stale one says nothing about
    /// now), on the ground, within `landingRadiusKm` of the arrival airport
    /// (on the ground at Newark is a diversion, not this landing), and after
    /// the departure — the tail parked at the destination before this flight
    /// left is its previous rotation, not this arrival.
    @discardableResult
    func recordLandingSample(onGround: Bool, velocity: Double, altitude: Double,
                             lat: Double?, lon: Double?,
                             at seen: Date, now: Date = .now) -> Bool {
        guard status == .active, let lat, let lon, arrivalLat != 0 || arrivalLon != 0 else { return false }
        guard now.timeIntervalSince(seen) < DepartureEvidence.freshWindow, seen <= now.addingTimeInterval(60) else { return false }
        let departed = actualDeparture ?? scheduledDeparture.addingTimeInterval(Double(max(0, delayMinutes)) * 60)
        guard seen > departed.addingTimeInterval(10 * 60) else { return false }
        switch GroundState.classify(onGround: onGround, velocity: velocity, altitude: altitude) {
        case .atGate, .taxiing: break
        case .airborne, .unknown: return false
        }
        let here = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let airport = CLLocationCoordinate2D(latitude: arrivalLat, longitude: arrivalLon)
        guard GeoMath.distanceKm(here, airport) <= Self.landingRadiusKm else { return false }
        // The provider's own runway time is more precise than "the first
        // sample in which it was already down".
        if actualArrival == nil {
            actualArrival = seen
            estimatedArrival = seen
        }
        status = .landed
        return true
    }
}
