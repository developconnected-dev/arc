import SwiftUI

/// Friends' filters, always directly above the cards: Add Friends, All, one
/// chip per group (with its members' faces) and one per friend (with theirs).
/// A chip narrows the stack, the list and the globe; long-pressing a friend's
/// chip sets how loudly their flights may notify you
/// (docs/superpowers/specs/2026-09-16-friends-floating-design.md).
///
/// Glass over the map, like the cards under it. The selected chip keeps its
/// inverted fill, so the one filter in force reads at a glance.
struct FriendFilterChips: View {
    @Binding var filter: FeedFilter
    let groups: [FriendGroup]
    let friends: [FriendsStore.FriendEntry]
    var onAdd: () -> Void
    var onManage: () -> Void

    /// Tall enough for a friend's face with its padding; the surface lays
    /// the row out at this height.
    static let height: CGFloat = 34

    /// Alert levels mirrored into observable state — see `friendChip`.
    @State private var chipLevels: [String: FriendNotificationLevel] = [:]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                addChip
                if !friends.isEmpty {
                    filterChip("All", filter: .all)
                    ForEach(groups) { group in groupChip(group) }
                    ForEach(friends) { entry in friendChip(entry) }
                }
            }
            .frame(height: Self.height)
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, MyTripsLayout.margin, for: .scrollContent)
        .frame(height: Self.height)
    }

    private var addChip: some View {
        Button(action: onAdd) {
            HStack(spacing: 6) {
                Image(systemName: "person.badge.plus").font(.system(size: 13, weight: .bold))
                Text("Add Friends").font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .frame(height: Self.height)
            .background(ArcTheme.action, in: Capsule())
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("friends-chip-add")
    }

    private func filterChip(_ label: String, filter target: FeedFilter) -> some View {
        let selected = filter == target
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { filter = target }
        } label: {
            Text(label).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(selected ? Color(.systemBackground) : .primary)
                .padding(.horizontal, 14)
                .modifier(ChipGround(selected: selected))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("friends-chip-all")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A group reads as one chip with a small stack of its members' faces, so
    /// "Family" is recognisable at a glance next to the individual chips.
    private func groupChip(_ group: FriendGroup) -> some View {
        let selected = filter == .group(group.id)
        let faces = friends.filter { group.memberIds.contains($0.id) }.prefix(3)
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                filter = selected ? .all : .group(group.id)
            }
        } label: {
            HStack(spacing: 6) {
                HStack(spacing: -8) {
                    ForEach(Array(faces)) { entry in
                        FriendAvatar(name: entry.user.display_name, size: 24,
                                     avatarURL: entry.user.avatar_url)
                            .overlay(Circle().stroke(selected ? Color.primary : Color(.systemBackground).opacity(0.8),
                                                     lineWidth: 1.5))
                    }
                }
                Text(group.name).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selected ? Color(.systemBackground) : .primary)
            }
            .padding(.leading, faces.isEmpty ? 13 : 5).padding(.trailing, 13)
            .modifier(ChipGround(selected: selected))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("friends-chip-group-\(group.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        // A group is edited where it was made; the chip is the short way there.
        .contextMenu {
            Button(action: onManage) {
                Label("Manage friends and groups", systemImage: "person.2")
            }
        }
    }

    private func friendChip(_ entry: FriendsStore.FriendEntry) -> some View {
        let selected = filter == .friend(entry.id)
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                filter = selected ? .all : .friend(entry.id)
            }
        } label: {
            HStack(spacing: 6) {
                FriendAvatar(name: entry.user.display_name, size: 26, avatarURL: entry.user.avatar_url)
                Text(entry.user.display_name).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selected ? Color(.systemBackground) : .primary)
            }
            .padding(.leading, 4).padding(.trailing, 13)
            .modifier(ChipGround(selected: selected))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("friends-chip-friend-\(entry.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        // Long-press: how much this friend's flying may interrupt you.
        // The level is mirrored into view state, same as ManageFriendsSheet:
        // FriendAlerts stores it in UserDefaults, which SwiftUI cannot
        // observe — read directly, tapping a level changed the setting but
        // the tick never moved.
        .contextMenu {
            let current = chipLevels[entry.id] ?? FriendAlerts.level(for: entry.id)
            ForEach(FriendNotificationLevel.allCases) { level in
                Button {
                    FriendAlerts.setLevel(level, for: entry.id)
                    chipLevels[entry.id] = level
                    Task { await FriendAlerts.process(entries: friends) }
                } label: {
                    Label(level.title, systemImage: current == level ? "checkmark" : level.icon)
                }
            }
        }
    }
}

/// A chip's capsule: glass over the map, or — for the filter in force — the
/// inverted fill it has always had. The whole capsule takes the tap: glass is
/// not a hit area of its own.
private struct ChipGround: ViewModifier {
    let selected: Bool
    func body(content: Content) -> some View {
        let sized = content
            .frame(height: FriendFilterChips.height)
            .contentShape(.capsule)
        if selected {
            sized.background(Color.primary, in: Capsule())
        } else {
            sized.glassEffect(ArcTheme.tripGlass, in: .capsule)
        }
    }
}
