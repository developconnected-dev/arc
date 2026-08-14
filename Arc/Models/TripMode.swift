import Foundation

/// How a leg travels. Arc began as a flight tracker; rail and sea legs are
/// stored in the very same `Flight` model rather than parallel types, because
/// every screen, widget, Live Activity and Supabase payload already reads that
/// one shape and forking it would fork all of them. This is the discriminator
/// that lets those shared surfaces phrase themselves correctly.
///
/// `air` is the default so that every flight already on the user's device
/// migrates without a schema plan — SwiftData adds a property with a default
/// for free, where renaming the model would not.
enum TripMode: String, Codable, CaseIterable, Sendable {
    case air, rail, sea

    /// What the code chip beside each endpoint is called. Flights have gates,
    /// trains have platforms, ferries have berths — using the flight word for
    /// all three is the kind of small wrongness that makes an app feel foreign.
    var boardingPointLabel: String {
        switch self {
        case .air: "Gate"
        case .rail: "Platform"
        case .sea: "Berth"
        }
    }

    /// SF Symbol for the leg, used wherever the plane glyph appears today.
    var symbol: String {
        switch self {
        case .air: "airplane"
        case .rail: "tram.fill"
        case .sea: "ferry.fill"
        }
    }

    /// What the operator of this leg is called.
    var operatorNoun: String {
        switch self {
        case .air: "Airline"
        case .rail: "Operator"
        case .sea: "Ferry Operator"
        }
    }

    // MARK: - Verbs
    //
    // A train does not land and a ferry is not in the air. These live here
    // rather than at each call site so the list row, the friends feed, the
    // widget and the Live Activity can't drift into describing the same journey
    // three different ways.

    /// Tiny all-caps state used on avatars and in list chrome.
    var inTransitShort: String {
        switch self {
        case .air: "IN AIR"
        case .rail: "EN ROUTE"
        case .sea: "AT SEA"
        }
    }

    var arrivedShort: String {
        switch self {
        case .air: "LANDED"
        case .rail, .sea: "ARRIVED"
        }
    }

    /// The same state as `inTransitShort`, in the sentence case that lines
    /// reading as prose need — the widget's status line, for one, where a train
    /// was being described as "In Flight".
    var inTransitLabel: String {
        switch self {
        case .air: "In Flight"
        case .rail: "En route"
        case .sea: "At sea"
        }
    }

    /// "Landing in 40m" / "Arriving in 40m".
    var arrivingVerb: String {
        switch self {
        case .air: "Landing"
        case .rail, .sea: "Arriving"
        }
    }

    /// "Landed 20m ago" / "Arrived 20m ago".
    var arrivedVerb: String {
        switch self {
        case .air: "Landed"
        case .rail, .sea: "Arrived"
        }
    }
}

/// How much the source actually knows about a leg — as distinct from how much
/// the UI would like to imply.
///
/// This exists because the three modes do not have comparable data, and
/// pretending otherwise would mean inventing facts. A flight and most trains
/// report a revised time against a scheduled one, so "On Time" is something we
/// were told. Mediterranean ferry operators publish a timetable and, separately,
/// prose disruption notices — there is no per-sailing delay figure anywhere in
/// the world's free data. A green "On Time" badge on a sailing would therefore
/// be Arc's guess wearing the costume of a fact.
///
/// So the tier rides along with the leg and the UI keys its confidence off it:
/// only `.live` earns a status colour and a delay figure.
enum DataTier: String, Codable, CaseIterable, Sendable {
    /// The provider reports actual/revised times against the schedule.
    case live
    /// A published timetable, and nothing else. Disruptions arrive separately.
    case scheduled
    /// The user typed it in. Nothing is enriching it.
    case manual

    /// May this leg display a delay figure and a status colour at all?
    var reportsPunctuality: Bool { self == .live }

    /// Shown where a flight would show "On Time" — naming the source of truth
    /// instead of asserting a punctuality nobody published.
    var qualifier: String? {
        switch self {
        case .live: nil
        case .scheduled: "Timetable"
        case .manual: "Added by you"
        }
    }
}
