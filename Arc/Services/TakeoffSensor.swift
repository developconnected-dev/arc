import Foundation
import CoreLocation
import CoreMotion
import SwiftData

/// Turns raw sensor samples into a takeoff or landing verdict — pure, no
/// CoreMotion, no CoreLocation, unit-tested. The service below feeds it.
///
/// Two independent takeoff paths, either sufficient:
///  - SPEED: nothing terrestrial does 80+ knots down a runway. Two
///    consecutive GPS fixes at ≥42 m/s are a take-off roll, full stop.
///  - CLIMB: the barometer sees the cabin's pressure altitude rise
///    steadily for minutes on end — no elevator or hill drive sustains
///    ~1 m/s for 120 metres. This is the path that works with location
///    denied, and the only sensor that also sees the DESCENT.
///
/// Landing is barometer-only and deliberately patient: a real descent
/// (≥250 m of cabin altitude given back) followed by minutes of pressure
/// quiet. The service adds a clock guard on top — a sensed "landed" is
/// only believed within the flight's own arrival window.
struct TakeoffDetector {
    enum Verdict: Equatable { case none, tookOff, landed }

    static let takeoffSpeedMS: Double = 42          // ≈ 82 kt over the ground
    static let takeoffClimbMeters: Double = 120     // cabin altitude gained
    static let climbAnchorMeters: Double = 30       // below this is ground noise
    static let takeoffClimbRateMS: Double = 1.0     // sustained, anchor → threshold
    static let landingDescentMeters: Double = 250
    static let landingQuietBandMeters: Double = 8
    static let landingQuietSeconds: TimeInterval = 240

    private(set) var airborne = false

    private var fastFixes = 0
    private var baselineAlt: Double?
    private var climbAnchor: (t: Date, alt: Double)?
    private var peakAlt: Double = -.greatestFiniteMagnitude
    private var quietAlt: Double?
    private var quietSince: Date?

    /// Another witness (the provider, ADS-B) confirmed the takeoff first:
    /// skip straight to the landing watch without claiming a verdict.
    mutating func noteAirborne() {
        airborne = true
    }

    /// One GPS fix. Speed in m/s; negative (no estimate) is ignored.
    mutating func speed(_ mps: Double, at t: Date) -> Verdict {
        guard !airborne, mps >= 0 else { return .none }
        fastFixes = mps >= Self.takeoffSpeedMS ? fastFixes + 1 : 0
        if fastFixes >= 2 {
            airborne = true
            return .tookOff
        }
        return .none
    }

    /// One barometer sample: RELATIVE altitude in metres (CMAltimeter's own
    /// frame — the session's start is zero, only differences mean anything).
    mutating func altitude(_ relAlt: Double, at t: Date) -> Verdict {
        if airborne {
            peakAlt = max(peakAlt, relAlt)
            // A new pressure level resets the quiet clock; holding one runs it.
            if quietAlt == nil || abs(relAlt - quietAlt!) > Self.landingQuietBandMeters {
                quietAlt = relAlt
                quietSince = t
                return .none
            }
            if peakAlt - relAlt >= Self.landingDescentMeters,
               let since = quietSince, t.timeIntervalSince(since) >= Self.landingQuietSeconds {
                return .landed
            }
            return .none
        }

        // On the ground: the lowest altitude seen is the field, and the climb
        // is measured against it — so a session started mid-pushback with the
        // altimeter drifting downward doesn't inflate the gain.
        baselineAlt = min(baselineAlt ?? relAlt, relAlt)
        let climb = relAlt - (baselineAlt ?? relAlt)
        if climb < Self.climbAnchorMeters {
            climbAnchor = nil
            return .none
        }
        // Rate is judged over the segment from the anchor (+30 m) up — the
        // part of the climb that cannot be ground noise.
        if climbAnchor == nil { climbAnchor = (t, relAlt) }
        guard climb >= Self.takeoffClimbMeters, let anchor = climbAnchor else { return .none }
        let dt = t.timeIntervalSince(anchor.t)
        guard dt > 0, (relAlt - anchor.alt) / dt >= Self.takeoffClimbRateMS else { return .none }
        airborne = true
        return .tookOff
    }
}

/// The wake ladder's brain — pure, no CoreLocation, so its what-if
/// scenarios run as tests: given the flights' windows and the clock, what
/// should a UI-less wake do — start the sensors, hold the process alive
/// until the window, or let iOS reclaim it?
enum TakeoffWakePlanner {
    enum Call: Equatable { case sensors(UUID), hold, sleep }
    struct Candidate {
        let id: UUID
        let offBlock: Date
        let windowEnd: Date     // expectedWheelsUp + DepartureEvidence.hardCap
        let departed: Bool
    }

    /// The window opens this far before off-block.
    static let windowLead: TimeInterval = 15 * 60
    /// A hold is only worth the power when the window is this close.
    static let holdHorizon: TimeInterval = 3 * 3600

    /// Candidates must arrive sorted by off-block; the earliest due flight
    /// wins, because a person boards one plane at a time.
    static func call(_ candidates: [Candidate], now: Date) -> Call {
        if let due = candidates.first(where: {
            !$0.departed
                && now >= $0.offBlock.addingTimeInterval(-windowLead)
                && now <= $0.windowEnd
        }) { return .sensors(due.id) }
        let holds = candidates.contains {
            !$0.departed
                && $0.offBlock.addingTimeInterval(-windowLead) > now
                && $0.offBlock < now.addingTimeInterval(holdHorizon)
        }
        return holds ? .hold : .sleep
    }
}

/// The device's own eyes on the takeoff — the one witness that works in
/// FULL airplane mode, where even the push channel is dark.
///
/// `DepartureEvidence.actualDeparture` has always named "the phone's own
/// sensors" as a witness source; this is that witness. Inside the takeoff
/// window (the tracker's own `watchingForTakeoff`) it runs the barometer
/// and, where the user allows location, a bounded background location
/// session — `CLBackgroundActivitySession` keeps a While-Using grant alive
/// in the background with the system's own blue indicator, which is the
/// honest way to keep sensing after the phone is pocketed. GPS is receive-
/// only, so both keep working after the radios go off.
///
/// On detection everything happens LOCALLY, on the very device the Live
/// Activity lives on: `recordGroundSample` sets the actual departure, the
/// card flips to confirmed In Air, and GPS stops (the altimeter alone —
/// nearly free — watches for the landing). Location never leaves the
/// device; only the derived fact ("wheels up at T") syncs when the network
/// returns, through the same paths any witness uses.
@MainActor
final class TakeoffSensor: NSObject {
    static let shared = TakeoffSensor()

    private var detector = TakeoffDetector()
    private var watching: UUID?
    private var modelContext: ModelContext?

    private let altimeter = CMAltimeter()
    private var altimeterRunning = false
    private lazy var location: CLLocationManager = {
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyBest
        m.activityType = .otherNavigation
        m.pausesLocationUpdatesAutomatically = false
        return m
    }()
    private var backgroundSession: CLBackgroundActivitySession?
    private var gpsRunning = false

    /// The wake ladder: sensors run fine in the background once STARTED, but
    /// a dead process cannot start one — no permission changes that. What
    /// Always authorization buys is the wake: iOS relaunches the app when it
    /// enters a monitored region, even force-quit. So with Always held, a
    /// geofence rings the departure airport; arrival relaunches us, a
    /// low-power location hold keeps the process alive to the window, and
    /// the window starts the real sensors — app never opened that day.
    private var container: ModelContainer?
    private var holdTimer: Timer?
    private var holding = false
    private nonisolated static let wakeRegionPrefix = "arc.takeoffwake."

    /// Called from the tracker's loop each pass. One aircraft at a time —
    /// a person boards one plane — and the sensor owns its own lifecycle
    /// past the takeoff (the landing watch outlives `watchingForTakeoff`).
    func reconcile(flights: [Flight], modelContext: ModelContext) {
        self.modelContext = modelContext
        armAirportWake(flights: flights)

        if let id = watching {
            guard let flight = flights.first(where: { $0.id == id }),
                  !flight.isDeleted, !flight.isCompleted,
                  Date.now < flight.effectiveArrival.addingTimeInterval(3600) else {
                stop()
                return
            }
            // Take-off confirmed by someone else (the provider beat us to
            // it): drop precise GPS, keep the barometer's landing watch.
            if flight.actualDeparture != nil, !detector.airborne {
                detector.noteAirborne()
                downgradeToLandingWatch()
            }
            return
        }

        // Not watching: is anything in its takeoff window?
        guard let flight = flights.first(where: { inTakeoffWindow($0) }) else { return }
        start(for: flight)
    }

    private func inTakeoffWindow(_ f: Flight) -> Bool {
        f.mode == .air && !f.isCompleted && !f.isDeleted
            && f.actualDeparture == nil
            && Date.now >= f.offBlock.addingTimeInterval(-TakeoffWakePlanner.windowLead)
            && Date.now <= f.expectedWheelsUp.addingTimeInterval(DepartureEvidence.hardCap)
    }

    private func start(for flight: Flight) {
        watching = flight.id
        detector = TakeoffDetector()

        // The barometer needs no location grant at all and is the sensor
        // that keeps working when everything else is refused.
        if CMAltimeter.isRelativeAltitudeAvailable(), !altimeterRunning {
            altimeterRunning = true
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let self, let data else { return }
                Task { @MainActor in
                    self.handle(self.detector.altitude(data.relativeAltitude.doubleValue, at: .now))
                    // The barometer is also the grounded phase's metronome:
                    // it re-judges the GPS profile as delay estimates slide.
                    self.reapplyGPSProfileIfDue()
                }
            }
        }

        switch location.authorizationStatus {
        case .authorizedAlways:
            startGPS()
        case .authorizedWhenInUse:
            startGPS()
            // The one escalation dialog iOS ever grants an app: spent here,
            // at the gate, where "wake Arc when you arrive at the airport"
            // is a sentence about the trip the user is on. A "keep While
            // Using" answer keeps today's behavior exactly.
            location.requestAlwaysAuthorization()
        case .notDetermined:
            // Asked at the one moment the question answers itself: the user
            // is at the gate with a flight about to leave. Asking for Always
            // shows the While-Using dialog now and lets iOS pose its own
            // upgrade question later; a refusal degrades to barometer-only.
            location.requestAlwaysAuthorization()
        default:
            break   // denied/restricted: barometer-only, foreground-only
        }
    }

    private func startGPS() {
        guard !gpsRunning else { return }
        gpsRunning = true
        holdTimer?.invalidate(); holdTimer = nil; holding = false
        // Best is the safe default (the hold may have dialed these down);
        // the profile then relaxes it while a posted delay holds the roll
        // far away.
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = kCLDistanceFilterNone
        applyGPSProfile()
        // The background session is what lets a While-Using grant keep
        // delivering after the phone is pocketed — with the system's own
        // indicator showing, which is the honest version of this feature.
        // An Always grant needs no session (and a background relaunch could
        // not legally create one).
        if location.authorizationStatus != .authorizedAlways {
            backgroundSession = CLBackgroundActivitySession()
        }
        location.allowsBackgroundLocationUpdates = true
        location.startUpdatingLocation()
    }

    /// Full GPS earns its power only when a takeoff roll is plausibly
    /// imminent. A posted delay slides expectedWheelsUp hours out — the
    /// window rightly stays open, but hunting satellites at Best accuracy
    /// through a three-hour gate delay is how an app earns its uninstall.
    /// Coarse until the final stretch; Best inside expectedWheelsUp−20m.
    /// The barometer never stops either way, and it re-checks this each
    /// minute, so a delay posted (or cleared) mid-window changes the
    /// profile within sixty seconds.
    private var lastProfileCheck = Date.distantPast

    private func applyGPSProfile() {
        guard let id = watching, !detector.airborne,
              let f = fetchFlights()?.first(where: { $0.id == id }) else { return }
        let rollNear = Date.now >= f.expectedWheelsUp.addingTimeInterval(-20 * 60)
        location.desiredAccuracy = rollNear ? kCLLocationAccuracyBest
                                            : kCLLocationAccuracyHundredMeters
        location.distanceFilter = rollNear ? kCLDistanceFilterNone : 100
    }

    private func reapplyGPSProfileIfDue() {
        guard gpsRunning, Date.now.timeIntervalSince(lastProfileCheck) > 60 else { return }
        lastProfileCheck = .now
        applyGPSProfile()
    }

    private func stopGPS() {
        guard gpsRunning else { return }
        gpsRunning = false
        location.stopUpdatingLocation()
        location.allowsBackgroundLocationUpdates = false
        backgroundSession?.invalidate()
        backgroundSession = nil
    }

    // MARK: - Airport wake (Always authorization only)

    /// Called from ArcApp.init so that a BACKGROUND RELAUNCH — iOS starting
    /// a dead Arc because it entered an airport geofence — has everything a
    /// wake needs: a data container, and an instantiated location manager
    /// whose delegate receives the very region event that caused the launch.
    func adoptContainer(_ container: ModelContainer) {
        self.container = container
        _ = location
    }

    /// Ring the departure airport of the next flight (or two) with a
    /// geofence. Entry relaunches the app even from force-quit; everything
    /// after that is `wake()`. Without Always this arms nothing.
    private func armAirportWake(flights: [Flight]) {
        guard location.authorizationStatus == .authorizedAlways,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let soon = Date.now.addingTimeInterval(36 * 3600)
        let wanted = flights
            .filter {
                $0.mode == .air && !$0.isCompleted && !$0.isDeleted
                    && $0.actualDeparture == nil
                    && $0.offBlock < soon
                    && Date.now <= $0.expectedWheelsUp.addingTimeInterval(DepartureEvidence.hardCap)
            }
            .sorted { $0.offBlock < $1.offBlock }
            .prefix(2)
        var regions: [String: CLCircularRegion] = [:]
        for f in wanted {
            guard let airport = ReferenceData.shared.airport(f.departureIATA) else { continue }
            let region = CLCircularRegion(
                center: airport.coordinate, radius: 2500,
                identifier: Self.wakeRegionPrefix + f.id.uuidString)
            region.notifyOnEntry = true
            region.notifyOnExit = false
            regions[region.identifier] = region
        }
        for monitored in location.monitoredRegions
        where monitored.identifier.hasPrefix(Self.wakeRegionPrefix) && regions[monitored.identifier] == nil {
            location.stopMonitoring(for: monitored)
        }
        for (id, region) in regions
        where !location.monitoredRegions.contains(where: { $0.identifier == id }) {
            location.startMonitoring(for: region)
            // Arming can happen when the user is ALREADY inside the fence
            // (flight added at the airport) — entry then never fires, so ask.
            location.requestState(for: region)
        }
    }

    /// A wake with no UI: the geofence fired, the hold timer ticked, or
    /// Always was just granted. The pure planner decides what this moment
    /// needs — full sensors, a coarse location hold that legally keeps the
    /// process alive until the window, or nothing.
    private func wake() {
        guard let flights = fetchFlights() else { return }
        armAirportWake(flights: flights)
        if watching != nil { return }
        let candidates = flights
            .filter { $0.mode == .air && !$0.isCompleted && !$0.isDeleted }
            .map {
                TakeoffWakePlanner.Candidate(
                    id: $0.id, offBlock: $0.offBlock,
                    windowEnd: $0.expectedWheelsUp.addingTimeInterval(DepartureEvidence.hardCap),
                    departed: $0.actualDeparture != nil)
            }
            .sorted { $0.offBlock < $1.offBlock }
        switch TakeoffWakePlanner.call(candidates, now: .now) {
        case .sensors(let id):
            if let due = flights.first(where: { $0.id == id }) { start(for: due) }
            stopHold()
        case .hold:
            startHold()
        case .sleep:
            stopHold()
        }
    }

    private func startHold() {
        guard location.authorizationStatus == .authorizedAlways,
              !gpsRunning, !holding else { return }
        holding = true
        location.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        location.distanceFilter = 500
        location.allowsBackgroundLocationUpdates = true
        location.startUpdatingLocation()
        // The process is alive, so a plain timer runs: re-judge each minute
        // and hand over to the real sensors the moment the window opens.
        holdTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in TakeoffSensor.shared.wake() }
        }
    }

    private func stopHold() {
        guard holding else { return }
        holding = false
        holdTimer?.invalidate(); holdTimer = nil
        if !gpsRunning {
            location.stopUpdatingLocation()
            location.allowsBackgroundLocationUpdates = false
        }
    }

    private func fetchFlights() -> [Flight]? {
        if modelContext == nil, let container { modelContext = ModelContext(container) }
        guard let context = modelContext else { return nil }
        return try? context.fetch(FetchDescriptor<Flight>())
    }

    private func stop() {
        watching = nil
        holdTimer?.invalidate(); holdTimer = nil; holding = false
        stopGPS()
        if altimeterRunning {
            altimeter.stopRelativeAltitudeUpdates()
            altimeterRunning = false
        }
        detector = TakeoffDetector()
    }

    /// After wheels-up the barometer alone senses the landing — but only a
    /// LIVE process hears a barometer. Stopping location entirely lets iOS
    /// suspend a backgrounded app within moments, and a suspended app has no
    /// sensors at all: the landing watch would exist only on paper. So the
    /// takeoff downgrades location to cell-tower accuracy instead of
    /// stopping it — the heartbeat that keeps the process (and the altimeter)
    /// alive through the flight, at a fraction of full GPS power — with a
    /// patient timer to end the watch if no landing is ever sensed.
    private func downgradeToLandingWatch() {
        guard gpsRunning else { return }   // no grant: foreground-only watch, nothing to keep alive
        // REDUCED, not three-kilometre: 3 km is served from cell towers, and
        // an ocean in airplane mode has none — CoreLocation can fall back to
        // GPS acquisition, the most expensive state the chip has, hunted for
        // hours inside a metal tube. Reduced is the tier Apple designed to be
        // served lazily from whatever is cheapest, including nothing. The
        // position is irrelevant anyway: this update stream exists solely to
        // keep the process — and with it the barometer — alive.
        location.desiredAccuracy = kCLLocationAccuracyReduced
        location.distanceFilter = 3000
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
            Task { @MainActor in TakeoffSensor.shared.expireLandingWatchIfDue() }
        }
    }

    private func expireLandingWatchIfDue() {
        guard let id = watching,
              let flights = fetchFlights(),
              let f = flights.first(where: { $0.id == id }), !f.isDeleted,
              Date.now < f.effectiveArrival.addingTimeInterval(3600) else {
            stop()
            wake()   // a connection's next leg may deserve a hold right now
            return
        }
    }

    private func handle(_ verdict: TakeoffDetector.Verdict) {
        guard verdict != .none,
              let id = watching, let context = modelContext,
              let flight = (try? context.fetch(FetchDescriptor<Flight>()))?
                  .first(where: { $0.id == id }),
              !flight.isDeleted else { return }

        switch verdict {
        case .tookOff:
            // Through the same gate every witness uses: classify guarantees
            // airborne (v > 40 or alt > 30), recordGroundSample sets the
            // actual departure, and the card on THIS device flips to a
            // confirmed In Air with no network anywhere.
            let tookOff = flight.recordGroundSample(onGround: false, velocity: 60, altitude: 300)
            if flight.statusRaw == FlightStatus.scheduled.rawValue
                || flight.statusRaw == FlightStatus.boarding.rawValue
                || flight.statusRaw == FlightStatus.gateClosed.rawValue {
                flight.statusRaw = FlightStatus.active.rawValue
            }
            try? context.save()
            downgradeToLandingWatch()   // coarse heartbeat; the altimeter watches
            let f = flight
            Task {
                await LiveActivityManager.shared.updateActivity(for: f)
                if tookOff { _ = try? await ArcSupabase.shared.shareFlight(f) }
            }
            if let all = try? context.fetch(FetchDescriptor<Flight>()) {
                WidgetSync.sync(flights: all)
            }

        case .landed:
            // The barometer knows a descent ended; the CLOCK says whether a
            // landing is even plausible — a sensed plateau half an hour
            // before the earliest arrival is a cabin quirk, not a runway.
            guard Date.now > flight.effectiveArrival.addingTimeInterval(-45 * 60) else { return }
            flight.statusRaw = FlightStatus.landed.rawValue
            if flight.actualArrival == nil { flight.actualArrival = .now }
            try? context.save()
            ArcNotifications.notifyLanded(flight: flight)
            let f = flight
            Task {
                await LiveActivityManager.shared.endActivity(for: f)
                _ = try? await ArcSupabase.shared.shareFlight(f)
            }
            if let all = try? context.fetch(FetchDescriptor<Flight>()) {
                WidgetSync.sync(flights: all)
            }
            stop()
            // Landed at the airport a connection departs from means standing
            // INSIDE the next leg's geofence — its entry event already fired
            // and will not fire again. Re-judge now, so a short layover gets
            // its hold without the app being opened.
            wake()

        case .none:
            break
        }
    }
}

extension TakeoffSensor: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map { (speed: $0.speed, at: $0.timestamp) }
        Task { @MainActor in
            for fix in fixes {
                self.handle(self.detector.speed(fix.speed, at: fix.at))
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            if self.watching != nil,
               status == .authorizedWhenInUse || status == .authorizedAlways {
                self.startGPS()
            }
            // A fresh Always grant is the moment the airport geofences can
            // finally be armed — don't wait for the next tracker pass.
            if status == .authorizedAlways { self.wake() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier.hasPrefix(TakeoffSensor.wakeRegionPrefix) else { return }
        Task { @MainActor in self.wake() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didDetermineState state: CLRegionState, for region: CLRegion) {
        guard state == .inside,
              region.identifier.hasPrefix(TakeoffSensor.wakeRegionPrefix) else { return }
        Task { @MainActor in self.wake() }
    }
}
