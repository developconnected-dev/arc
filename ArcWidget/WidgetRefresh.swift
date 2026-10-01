import Foundation
import WidgetKit

/// The widget's own line to the Worker.
///
/// The App Group snapshot is only ever written by the app, so with the app
/// closed the home screen simply froze on whatever was last seen — a gate
/// change or a delay reached the Live Activity (the Worker pushes those) but
/// never the widget until the user opened Arc, which is backwards: the widget
/// is the surface for NOT opening the app. WidgetKit lets a timeline provider
/// do network work, so the widget asks about its hero leg itself and patches
/// the snapshot before rendering.
///
/// Budgeted deliberately: WidgetKit allows a few dozen reloads a day, so only
/// the one leg that is live-or-imminent is refreshed, only for air legs whose
/// source reports revisions (a timetable-only train has nothing to refresh),
/// and never more often than every few minutes.
enum WidgetRefresh {
    /// Refresh no more often than this, regardless of how many reloads iOS grants.
    static let minInterval: TimeInterval = 4 * 60
    /// The window around a leg in which its facts can still change.
    static let leadTime: TimeInterval = 24 * 3600
    static let tailTime: TimeInterval = 45 * 60

    private static var baseURL: URL {
        let stored = WidgetData.sharedDefaults?.string(forKey: "apiEndpoint")
        return URL(string: stored ?? "") ?? ArcConfig.defaultAPIURL
    }

    /// The leg the widget will lead with, refreshed against the Worker when it
    /// is worth asking. Returns the (possibly patched) full list.
    static func refreshed(_ flights: [WidgetFlight], now: Date = .now) async -> [WidgetFlight] {
        guard let hero = flights.first(where: { $0.isCurrent(at: now) }),
              hero.mode == .air, hero.dataTier.reportsPunctuality,
              hero.scheduledDeparture.timeIntervalSince(now) < leadTime,
              hero.effectiveArrival.timeIntervalSince(now) > -tailTime
        else { return flights }
        if let last = hero.updatedAt, now.timeIntervalSince(last) < minInterval { return flights }

        guard let leg = await fetchLeg(number: hero.flightNumber,
                                       date: hero.scheduledDeparture, zone: hero.departureTZ,
                                       dep: hero.departureIATA, arr: hero.arrivalIATA)
        else { return flights }

        var patched = flights
        guard let i = patched.firstIndex(where: { $0.id == hero.id }) else { return flights }
        patched[i] = apply(leg, to: hero, at: now)
        // Persist so the app (and the next timeline) starts from the fresh facts.
        WidgetData.save(flights: patched)
        return patched
    }

    // MARK: - Worker call

    /// The subset of the Worker's `/flight` shape the widget cares about.
    private struct Leg: Decodable {
        let dep_iata: String
        let arr_iata: String
        let status: String
        /// The leg's own schedule — what tells our leg from the daily
        /// sibling, and a re-filing from the cancelled row it replaces.
        let dep_scheduled: String?
        /// The provider's "likely cancelled" guess (see the Worker's legs.ts).
        let cancel_uncertain: Bool?
        let delay: Int?
        let dep_gate: String?
        let dep_terminal: String?
        let arr_gate: String?
        let arr_terminal: String?
        let arr_baggage: String?
        let arr_actual: String?
        let arr_estimated: String?
        // The departure side of the same question. Without these the widget's
        // own refresh rebuilt the snapshot with no confirmed take-off and no
        // wheels-up estimate, so the home screen re-hedged a flight the app
        // already knew was airborne — and hedged it against the gate time.
        let dep_actual: String?
        let dep_runway_estimated: String?
        let dep_live: Bool?
    }

    private static func fetchLeg(number: String, date: Date, zone: String?,
                                 dep: String, arr: String) async -> Leg? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? .current
        var comps = URLComponents(url: baseURL.appending(path: "/flight"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "number", value: number.replacingOccurrences(of: " ", with: "")),
            URLQueryItem(name: "date", value: f.string(from: date)),
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let legs = try? JSONDecoder().decode([Leg].self, from: data)
        else { return nil }
        // A number flies several legs a day; take ours — the route matches,
        // and among route matches the one scheduled closest to our own leg.
        // When no leg matches the route, a lone answer is still plausibly
        // ours with a hollowed endpoint; among SEVERAL, "the first" is
        // another sector (or another day, on an after-midnight route), and
        // patching the hero card from it stamped a different flight's status
        // onto the home screen. Better unchanged than wrong.
        let routed = legs.filter { $0.dep_iata.caseInsensitiveCompare(dep) == .orderedSame
                                   && $0.arr_iata.caseInsensitiveCompare(arr) == .orderedSame }
        guard !routed.isEmpty else { return legs.count == 1 ? legs.first : nil }
        func sched(_ l: Leg) -> Date? { parseAPIDate(l.dep_scheduled) }
        func drift(_ l: Leg) -> TimeInterval {
            sched(l).map { abs($0.timeIntervalSince(date)) } ?? .greatestFiniteMagnitude
        }
        func disfavored(_ l: Leg) -> Bool { l.status == "cancelled" || l.cancel_uncertain == true }
        guard let best = routed.min(by: { drift($0) < drift($1) }) else { return nil }
        // A reschedule filed as two rows: the cancelled original's operating
        // re-filing within the window IS the flight, moved — same rule as
        // ScheduleBackfill.preferOperating and the Worker's pickLeg.
        if disfavored(best), let bestDep = sched(best) {
            let replacement = routed
                .filter { !disfavored($0) }
                .compactMap { l -> (Leg, TimeInterval)? in
                    guard let d = sched(l) else { return nil }
                    let gap = abs(d.timeIntervalSince(bestDep))
                    return gap <= 3 * 3600 ? (l, gap) : nil
                }
                .min { $0.1 < $1.1 }?.0
            if let replacement { return replacement }
        }
        return best
    }

    private static func apply(_ leg: Leg, to f: WidgetFlight, at now: Date) -> WidgetFlight {
        var out = WidgetFlight(
            id: f.id, flightNumber: f.flightNumber, airline: f.airline,
            departureIATA: f.departureIATA, arrivalIATA: f.arrivalIATA,
            departureCity: f.departureCity, arrivalCity: f.arrivalCity,
            scheduledDeparture: f.scheduledDeparture, scheduledArrival: f.scheduledArrival,
            status: leg.status.isEmpty ? f.status : leg.status,
            delayMinutes: effectiveDelay(leg, storedScheduled: f.scheduledDeparture) ?? f.delayMinutes,
            // A provider null must not erase what the app already knew.
            departureGate: leg.dep_gate ?? f.departureGate,
            progress: f.progress,
            predictedDelayMinutes: f.predictedDelayMinutes,
            mode: f.mode, dataTier: f.dataTier)
        out.departureTerminal = leg.dep_terminal ?? f.departureTerminal
        out.arrivalGate = leg.arr_gate ?? f.arrivalGate
        out.arrivalTerminal = leg.arr_terminal ?? f.arrivalTerminal
        out.baggageClaim = leg.arr_baggage ?? f.baggageClaim
        out.estimatedArrival = parseAPIDate(leg.arr_actual ?? leg.arr_estimated) ?? f.estimatedArrival
        out.departureTZ = f.departureTZ
        out.arrivalTZ = f.arrivalTZ
        // Departure evidence: never lose what the app already established.
        out.actualDeparture = parseAPIDate(leg.dep_actual) ?? f.actualDeparture
        out.estimatedTakeoff = parseAPIDate(leg.dep_runway_estimated) ?? f.estimatedTakeoff
        out.groundState = f.groundState
        out.groundObservedAt = f.groundObservedAt
        out.taxiStartedAt = f.taxiStartedAt
        out.taxiPriorMinutes = f.taxiPriorMinutes
        // A source that would have reported a take-off and didn't has just
        // told us it is still on the ground — which pushes the moment the
        // widget may presume otherwise.
        out.lastSeenOnGround = (out.actualDeparture == nil && leg.dep_live == true)
            ? now : f.lastSeenOnGround
        out.updatedAt = now
        return out
    }

    /// Delay against the SNAPSHOT's schedule: a retimed leg — or the
    /// re-filing chosen over a cancelled row above — carries its shift as
    /// lateness, so the countdown lands on the real departure. Identical
    /// schedules hand the leg's delay back unchanged; never negative.
    /// Mirrors ScheduleBackfill.effectiveDelayMinutes.
    private static func effectiveDelay(_ leg: Leg, storedScheduled: Date) -> Int? {
        guard let raw = leg.delay.map({ max(0, $0) }) else { return nil }
        guard let legSched = parseAPIDate(leg.dep_scheduled) else { return raw }
        return max(0, Int((legSched.timeIntervalSince(storedScheduled) / 60 + Double(raw)).rounded()))
    }

    private static func parseAPIDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }
}
