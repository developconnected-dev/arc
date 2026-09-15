import Foundation

/// What My Trips draws one glass card for: a leg on its own, or the legs a
/// connection binds (`ConnectionPlanner.detectConnections`). Built in the
/// list's own order, so the first journey is the one the folded stack shows.
struct TripJourney: Identifiable, Equatable {
    let legs: [Flight]

    /// The first leg's id: stable for as long as the journey starts there.
    var id: UUID { legs[0].id }

    static func == (a: TripJourney, b: TripJourney) -> Bool {
        a.legs.map(\.id) == b.legs.map(\.id)
    }

    /// Folds each connection's outbound into the journey of the inbound drawn
    /// directly above it. A chain (A→B→C) is one journey; legs the list does
    /// not draw next to each other stay apart.
    static func group(_ listed: [Flight],
                      connections: [(inbound: Flight, outbound: Flight)]) -> [TripJourney] {
        let next = Dictionary(connections.map { ($0.inbound.id, $0.outbound.id) },
                              uniquingKeysWith: { first, _ in first })
        var grouped: [[Flight]] = []
        for flight in listed {
            if let last = grouped.last?.last, next[last.id] == flight.id {
                grouped[grouped.count - 1].append(flight)
            } else {
                grouped.append([flight])
            }
        }
        return grouped.map(TripJourney.init(legs:))
    }
}
