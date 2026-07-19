import SwiftUI
import SwiftData

/// Light Friends empty state (matches Flighty). Social backend is deferred —
/// the Supabase-backed FriendsTabView remains in the project for later.
struct FriendsSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Friends").font(ArcTheme.screenTitle)
                Spacer()
                circleIcon("ellipsis")
                circleIcon("square.and.arrow.up")
                Image(systemName: "person.crop.circle.fill").font(.system(size: 34))
                    .foregroundStyle(Color(.systemGray3), Color(.systemGray5))
            }
            .padding(.horizontal, 20).padding(.top, 4)

            HStack(spacing: 14) {
                Text("Everyone").font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Color(.secondarySystemFill), in: Capsule())
                Text("Today").font(.system(size: 15)).foregroundStyle(.secondary)
                Spacer()
                Label("Add Friend", systemImage: "plus.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ArcTheme.action)
            }
            .padding(.horizontal, 20).padding(.top, 14)

            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "person.2.circle")
                    .font(.system(size: 52)).foregroundStyle(.tertiary)
                Text("Add Friends' Flights").font(.system(size: 20, weight: .bold))
                Text("Add an Arc friend to see their flights automatically, or tap Search to add a flight.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func circleIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary).frame(width: 36, height: 36)
            .background(Color(.secondarySystemFill), in: Circle())
    }
}
