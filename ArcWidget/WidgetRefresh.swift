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
        return URL(string: stored ?? "") ?? URL(string: "https://arc-backend.owncalai.workers.dev")!
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
        let delay: Int?
        let dep_gate: String?
        let dep_terminal: String?
        let arr_gate: String?
        let arr_terminal: String?
        let arr_baggage: String?
        let arr_actual: String?
        let arr_estimated: String?
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
        // A number flies several legs a day; take ours, else the first.
        return legs.first { $0.dep_iata.caseInsensitiveCompare(dep) == .orderedSame
                            && $0.arr_iata.caseInsensitiveCompare(arr) == .orderedSame }
            ?? legs.first
    }

    private static func apply(_ leg: Leg, to f: WidgetFlight, at now: Date) -> WidgetFlight {
        var out = WidgetFlight(
            id: f.id, flightNumber: f.flightNumber, airline: f.airline,
            departureIATA: f.departureIATA, arrivalIATA: f.arrivalIATA,
            departureCity: f.departureCity, arrivalCity: f.arrivalCity,
            scheduledDeparture: f.scheduledDeparture, scheduledArrival: f.scheduledArrival,
            status: leg.status.isEmpty ? f.status : leg.status,
            delayMinutes: leg.delay ?? f.delayMinutes,
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
        out.updatedAt = now
        return out
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
