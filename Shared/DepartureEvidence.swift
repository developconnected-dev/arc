import Foundation

/// Has this flight actually left the ground?
///
/// Every Arc surface used to answer that from the clock: past the (delayed)
/// scheduled departure, therefore flying. But airlines publish *gate* times,
/// and the distance from the gate to the runway is the taxi — routinely 20
/// to 40 minutes at a hub, occasionally an hour in an ATC hold, and never
/// published as a delay because the aircraft did push back on time. A
/// traveller sat in exactly that hold while her home screen told her, and
/// everyone watching her, that she was in the air.
///
/// So the question is answered from evidence instead, in one place that the
/// app, the widget, the Live Activity, the friends feed and the share page
/// all consult, because the worst outcome is not being cautious — it is two
/// Arc surfaces disagreeing about whether someone has taken off.
///
/// The evidence, best first:
///   1. a reported take-off (`actualDeparture`) or an aircraft seen airborne
///   2. a fresh sighting on the ground — at the stand, or rolling
///   3. the clock, measured against when wheels-up is *expected*: the
///      provider's own estimate, or off-block plus what this airport's taxi
///      actually takes (`taxiPriorMinutes`, learned per airport per hour)
///
/// Past the expected wheels-up with nothing confirmed, Arc commits — but to
/// `presumedAirborne`, which surfaces render muted and never as a green
/// fact. It is the difference between "she's flying" and "she should be
/// flying by now, nobody has told us".
public struct DepartureEvidence: Equatable, Sendable {
    /// Gate departure: the schedule plus whatever delay the airline admits.
    public var offBlock: Date
    /// The provider's own estimate of wheels-up, when it offers one.
    public var estimatedTakeoff: Date?
    /// A take-off somebody reported: the provider, ADS-B, or the phone's own
    /// sensors. The one thing that ends every hedge.
    public var actualDeparture: Date?
    /// The last classification of an ADS-B sample: at_gate, taxiing, airborne.
    public var groundState: String?
    public var groundObservedAt: Date?
    /// When the aircraft was first seen rolling — what "Taxiing for 14m" counts from.
    public var taxiStartedAt: Date?
    /// The last moment a source that *could* have reported a departure still
    /// showed none. Only meaningful with live coverage (see `isLiveCovered`).
    public var lastSeenOnGround: Date?
    /// This airport's p85 taxi-out for this hour, learned from observed
    /// take-offs; 20 minutes until it has taught us better.
    public var taxiPriorMinutes: Int
    /// Whether live data exists for this departure at all. Without it no
    /// confirmation will ever arrive, so the absence of one proves nothing.
    public var isLiveCovered: Bool

    /// How long a sighting stays worth believing.
    public static let freshWindow: TimeInterval = 15 * 60
    /// The longest the clock alone will hedge before presuming.
    public static let hardCap: TimeInterval = 90 * 60
    public static let defaultTaxiPrior = 20

    public init(
        offBlock: Date,
        estimatedTakeoff: Date? = nil,
        actualDeparture: Date? = nil,
        groundState: String? = nil,
        groundObservedAt: Date? = nil,
        taxiStartedAt: Date? = nil,
        lastSeenOnGround: Date? = nil,
        taxiPriorMinutes: Int = DepartureEvidence.defaultTaxiPrior,
        isLiveCovered: Bool = true
    ) {
        self.offBlock = offBlock
        self.estimatedTakeoff = estimatedTakeoff
        self.actualDeparture = actualDeparture
        self.groundState = groundState
        self.groundObservedAt = groundObservedAt
        self.taxiStartedAt = taxiStartedAt
        self.lastSeenOnGround = lastSeenOnGround
        self.taxiPriorMinutes = taxiPriorMinutes
        self.isLiveCovered = isLiveCovered
    }

    /// When Arc expects the wheels to leave the ground.
    ///
    /// Never sooner than off-block plus this airport's taxi, never sooner
    /// than the provider's own estimate, and never within a taxi of the last
    /// time somebody saw the aircraft still on the ground — that last term is
    /// what keeps a phone that went dark at the door from committing on a
    /// timetable it already knew was being overtaken. Capped, so a stream of
    /// "still nothing" refreshes can't hedge for ever.
    public var expectedWheelsUp: Date {
        let taxi = Double(max(0, taxiPriorMinutes)) * 60
        var expected = offBlock.addingTimeInterval(taxi)
        if let estimate = estimatedTakeoff, estimate > expected { expected = estimate }
        if isLiveCovered, let seen = lastSeenOnGround {
            let slid = min(seen.addingTimeInterval(taxi), offBlock.addingTimeInterval(Self.hardCap))
            if slid > expected { expected = slid }
        }
        return expected
    }

    public func phase(at now: Date) -> DeparturePhase {
        // A confirmation that hasn't happened yet is a filing, not a fact.
        if let actual = actualDeparture, actual <= now { return .airborne }
        let sightingIsFresh = groundObservedAt.map { now.timeIntervalSince($0) < Self.freshWindow && $0 <= now } ?? false
        if sightingIsFresh, groundState == "airborne" { return .airborne }
        // Seen ROLLING outranks the clock in BOTH directions. The old order
        // asked "before off-block?" first — and off-block is the schedule
        // plus the FILED delay, so a pushback any earlier than the airline's
        // (routinely overstated) delay put the entire real taxi "before
        // departure": every surface held its countdown through the roll and
        // jumped straight to In Air at wheels-up. Taxiing never showed.
        if sightingIsFresh, groundState == "taxiing" { return .taxiing(since: taxiStartedAt) }
        // Once it has started rolling, a pause is still the taxi — most of a
        // 35-minute taxi at a busy hub is spent stopped in the queue, and
        // flickering between "Taxiing" and anything else every time the
        // aircraft holds is worse than either. Clock-independent, like the
        // roll itself.
        if sightingIsFresh, groundState == "at_gate", let started = taxiStartedAt {
            return .taxiing(since: started)
        }
        if now < offBlock { return .beforeDeparture }
        // Still parked at the gate, watched, past the gate time: departing.
        if sightingIsFresh, groundState == "at_gate" { return .departing }
        return now < expectedWheelsUp ? .departing : .presumedAirborne
    }
}

/// Where a flight is between the gate and the air, and how sure Arc is.
public enum DeparturePhase: Equatable, Sendable {
    /// Still ahead of its gate departure.
    case beforeDeparture
    /// Past the gate time, not expected to be off the ground yet.
    case departing
    /// Seen rolling. `since` is when the taxi started, when that is known.
    case taxiing(since: Date?)
    /// Past the expected wheels-up, with nobody confirming it. Arc believes
    /// it is flying and says so *as a presumption* — muted, never green.
    case presumedAirborne
    /// Confirmed off the ground by a source that would know.
    case airborne

    /// True while Arc is hedging rather than stating a confirmed fact.
    public var isHedged: Bool {
        switch self {
        case .departing, .taxiing, .presumedAirborne: return true
        case .beforeDeparture, .airborne: return false
        }
    }

    /// Whether the surfaces should treat the leg as under way — countdowns
    /// to arrival, progress bars, in-transit layout.
    public var isOffTheGround: Bool {
        switch self {
        case .presumedAirborne, .airborne: return true
        case .beforeDeparture, .departing, .taxiing: return false
        }
    }

    /// Whether a source has actually confirmed the take-off — the bar for
    /// green, for "In Air", and for anything stated as fact.
    public var isConfirmed: Bool { self == .airborne }
}

/// What one ADS-B sample says the aircraft is doing. Mirror of the Worker's
/// `classifyGround` (backend/src/ground.ts) — deliberately duplicated rather
/// than derived, so a device and the server can never disagree about what
/// "taxiing" means, and kept in the same units /position speaks (m/s, metres).
public enum GroundState: String, Sendable {
    case atGate = "at_gate"
    case taxiing
    case airborne
    case unknown

    public static func classify(onGround: Bool, velocity: Double, altitude: Double) -> GroundState {
        if onGround {
            // 3 m/s ≈ 6 kt: a pushback already reads as taxiing, which is
            // what someone watching wants to know — they're moving.
            return velocity >= 3 ? .taxiing : .atGate
        }
        return (altitude > 30 || velocity > 40) ? .airborne : .unknown
    }
}
