import SwiftUI

/// Identity uses the scheduled instant, never a changing delay/ETA. Unknown
/// routes or dates remain separate rather than claiming people travel together.
struct SharedJourneyKey: Hashable {
    let mode: String
    let number: String
    let from: String
    let to: String
    let minute: Int

    init?(mode: TripMode, number: String, from: String, to: String, departure: Date?) {
        let number = number.filter { !$0.isWhitespace }.uppercased()
        let from = from.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let to = to.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !number.isEmpty, !from.isEmpty, !to.isEmpty,
              from != "---", to != "---", let departure else { return nil }
        self.mode = mode.rawValue
        self.number = number
        self.from = from
        self.to = to
        minute = Int(floor(departure.timeIntervalSince1970 / 60))
    }
    init?(_ flight: ArcSupabase.SharedFlight) {
        self.init(mode: flight.tripMode, number: flight.flight_number,
                  from: flight.departure_iata, to: flight.arrival_iata,
                  departure: DateHelpers.parseAPIDate(flight.scheduled_departure))
    }
    init?(_ flight: Flight) {
        self.init(mode: flight.mode, number: flight.flightNumber,
                  from: flight.departureIATA, to: flight.arrivalIATA,
                  departure: flight.scheduledDeparture)
    }
    var id: String { "\(mode)|\(number)|\(from)|\(to)|\(minute)" }
}

struct FriendFlightGroup: Identifiable {
    let id: String
    let items: [FriendsStore.FeedItem]
    let myFlightID: UUID?
    var representative: FriendsStore.FeedItem { items[0] }
    var users: [ArcSupabase.ArcUser] { items.map(\.user) }

    static func group(_ feed: [FriendsStore.FeedItem], myFlights: [Flight] = []) -> [Self] {
        var order: [String] = []
        var buckets: [String: [FriendsStore.FeedItem]] = [:]
        let own = myFlights.filter { $0.status != .cancelled }
        for item in feed {
            let id = SharedJourneyKey(item.flight)?.id ?? "unmatched:\(item.id)"
            if buckets[id] == nil { order.append(id) }
            buckets[id, default: []].append(item)
        }
        return order.map { id in
            // The most recently verified copy supplies status, while stable
            // user ordering keeps avatar positions from shuffling on refresh.
            let sorted = buckets[id]!.sorted {
                let a = $0.flight.lastKnownAt ?? .distantPast
                let b = $1.flight.lastKnownAt ?? .distantPast
                return a == b ? $0.id < $1.id : a > b
            }
            var seen: Set<String> = []
            let unique = sorted.filter { seen.insert($0.user.id).inserted }
            let key = SharedJourneyKey(unique[0].flight)
            let mine = key.flatMap { key in own.first { SharedJourneyKey($0) == key } }
            return Self(id: id, items: unique, myFlightID: mine?.id)
        }
    }
}

/// Same three-avatar overlap and overflow count as the Live Activity.
struct TravellerAvatarStack: View {
    let users: [ArcSupabase.ArcUser]
    var includesMe = false
    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: -7) {
                ForEach(users.sorted { $0.id < $1.id }.prefix(3), id: \.id) { user in
                    FriendAvatar(name: user.display_name, size: 20, avatarURL: user.avatar_url)
                        .overlay(Circle().strokeBorder(Color(.systemBackground).opacity(0.8), lineWidth: 1))
                }
            }
            if users.count > 3 {
                Text("+\(users.count - 3)").font(.caption2.bold()).foregroundStyle(.secondary)
            }
            if includesMe {
                Text("You").font(.caption2.bold()).foregroundStyle(ArcTheme.brand)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(((includesMe ? ["You"] : []) + users.map(\.display_name).sorted()).joined(separator: ", "))
    }
}
