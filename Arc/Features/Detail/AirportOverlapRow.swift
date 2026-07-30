import SwiftUI

/// "You and Anna are both at ZRH" — shown on the flight it concerns, while the
/// window is open, and dismissible.
///
/// It used to live permanently on the flight list, which is the wrong place
/// twice over: the list is about your flights, not about coincidences, and a
/// banner that is always there stops being read. The moment this is useful is
/// when it's discovered, which is what the notification is for; this row is
/// just where you look it up afterwards.
struct AirportOverlapRow: View {
    let flight: Flight

    @State private var dismissed: Set<String> = []

    private var overlaps: [FriendsStore.AirportOverlap] {
        FriendsStore.shared.activeOverlaps.filter { overlap in
            let airport = overlap.airportIATA.uppercased()
            let mine = [flight.departureIATA.uppercased(), flight.arrivalIATA.uppercased()]
            return mine.contains(airport) && !dismissed.contains(key(overlap))
        }
    }

    private func key(_ o: FriendsStore.AirportOverlap) -> String {
        "\(o.friend.id)|\(o.airportIATA)"
    }

    var body: some View {
        ForEach(overlaps) { overlap in
            HStack(spacing: 12) {
                FriendAvatar(name: overlap.friend.display_name, size: 36,
                             avatarURL: overlap.friend.avatar_url)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(overlap.friend.display_name) is at \(overlap.airportIATA) too")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("\(overlap.isToday ? "Today" : "Same window") · \(overlap.timeWindow)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeOut) { _ = dismissed.insert(key(overlap)) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}
