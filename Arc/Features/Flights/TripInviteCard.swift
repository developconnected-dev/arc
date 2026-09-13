import SwiftUI

/// "Carl added this trip for you together" — pinned above My Trips until it's
/// answered. The trip itself renders as the very row it will become on Accept,
/// so there's no surprise; the two pills are the only way it moves. Nothing
/// lands in the list without a tap.
struct TripInviteCard: View {
    let item: FriendsStore.TripInviteItem
    var onOpen: (Flight) -> Void
    var onAccept: () -> Void
    var onDecline: () -> Void

    /// Display-only — NOT inserted into SwiftData. Accept materialises a
    /// fresh one; this exists so the preview and the eventual row agree.
    @State private var preview: Flight

    init(item: FriendsStore.TripInviteItem,
         onOpen: @escaping (Flight) -> Void,
         onAccept: @escaping () -> Void,
         onDecline: @escaping () -> Void) {
        self.item = item
        self.onOpen = onOpen
        self.onAccept = onAccept
        self.onDecline = onDecline
        _preview = State(initialValue: item.invite.flight.materialize())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                FriendAvatar(name: item.sender.display_name, size: 28,
                             avatarURL: item.sender.avatar_url)
                // Interpolated, not concatenated: `Text + Text` is deprecated
                // in iOS 26, and a styled Text inside the string keeps the
                // bold name.
                Text("\(Text(item.sender.display_name).fontWeight(.bold)) added this trip for you together")
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            Button { onOpen(preview) } label: {
                FlightRowCard(flight: preview, isPreview: true)
            }
            .buttonStyle(.plain)
            // The row carries its own 14pt inset on every side; pull it back
            // so its content lines up with the header and the pills.
            .padding(.horizontal, -14)
            .padding(.vertical, -8)

            HStack(spacing: 10) {
                pill("Decline", fill: Color(.tertiarySystemFill), text: .secondary, action: onDecline)
                pill("Accept", fill: ArcTheme.action, text: .white, action: onAccept)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func pill(_ title: String, fill: Color, text: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(text)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(fill, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
