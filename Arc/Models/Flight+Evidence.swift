import Foundation

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

    var departurePhase: DeparturePhase { departureEvidence.phase(at: .now) }

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
}
