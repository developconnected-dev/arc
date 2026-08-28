import SwiftUI

/// Manage friends: who may interrupt you, who you're still connected to, and
/// how they're grouped. Reached from the people button beside "Add Friends".
///
/// Per-friend notification levels used to live in Settings, which is the wrong
/// place — they're about these people, not about the app, so they belong next
/// to the friends themselves.
struct ManageFriendsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = FriendsStore.shared
    @State private var groups: [FriendGroup] = []
    @State private var levels: [String: FriendNotificationLevel] = [:]
    @State private var editingGroup: FriendGroup?
    @State private var pendingRemoval: FriendsStore.FriendEntry?

    var body: some View {
        NavigationStack {
            List {
                groupsSection
                friendsSection
            }
            .navigationTitle("Manage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            .sheet(item: $editingGroup) { group in
                GroupEditorSheet(
                    group: group,
                    friends: store.friends,
                    onSave: { FriendGroups.upsert($0); reload() },
                    onDelete: { FriendGroups.delete(group.id); reload() })
            }
            .alert("Remove friend?", isPresented: removalBinding, presenting: pendingRemoval) { entry in
                Button("Remove", role: .destructive) { remove(entry) }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            } message: { entry in
                Text("You and \(entry.user.display_name) will stop sharing flights. You can reconnect any time with a new invite link.")
            }
        }
        .onAppear(perform: reload)
    }

    // MARK: Groups

    private var groupsSection: some View {
        Section {
            ForEach(groups) { group in
                Button { editingGroup = group } label: { groupRow(group) }
                    .buttonStyle(.plain)
            }
            Button {
                editingGroup = FriendGroup(name: "")
            } label: {
                Label("New Group", systemImage: "plus.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ArcTheme.action)
            }
            .disabled(store.friends.isEmpty)
        } header: {
            Text("Groups")
        } footer: {
            Text("Group your people — family, close friends — then filter the feed to just them, or set how loudly the whole group may interrupt you at once.")
        }
    }

    private func groupRow(_ group: FriendGroup) -> some View {
        HStack(spacing: 12) {
            avatarStack(for: group)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name.isEmpty ? "Untitled" : group.name)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                Text(memberCount(group))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
        }
    }

    /// Overlapping avatars, capped — a group of twelve shouldn't push the name
    /// off the row.
    private func avatarStack(for group: FriendGroup) -> some View {
        let members = store.friends.filter { group.memberIds.contains($0.id) }.prefix(3)
        return HStack(spacing: -10) {
            ForEach(Array(members)) { entry in
                FriendAvatar(name: entry.user.display_name, size: 30,
                             avatarURL: entry.user.avatar_url)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
            }
            if members.isEmpty {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color(.secondarySystemFill), in: Circle())
            }
        }
        .frame(width: 62, alignment: .leading)
    }

    private func memberCount(_ group: FriendGroup) -> String {
        let n = store.friends.filter { group.memberIds.contains($0.id) }.count
        return n == 1 ? "1 person" : "\(n) people"
    }

    // MARK: Friends

    private var friendsSection: some View {
        Section {
            if store.friends.isEmpty {
                Text("No friends yet — share an invite link to connect.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            ForEach(store.friends) { entry in
                HStack(spacing: 12) {
                    FriendAvatar(name: entry.user.display_name, size: 32,
                                 avatarURL: entry.user.avatar_url)
                    Text(entry.user.display_name)
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    levelMenu(for: entry.id)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { pendingRemoval = entry } label: {
                        Label("Remove", systemImage: "person.badge.minus")
                    }
                }
            }
        } header: {
            Text("Friends")
        } footer: {
            Text("Live Activity: their flight appears in your Dynamic Island and lock screen while they fly. Alerts: takeoff, landing and delay notifications only. Swipe a friend to remove them.")
        }
    }

    private func levelMenu(for friendId: String) -> some View {
        let current = levels[friendId] ?? FriendAlerts.level(for: friendId)
        return Menu {
            ForEach(FriendNotificationLevel.allCases) { level in
                Button {
                    FriendAlerts.setLevel(level, for: friendId)
                    levels[friendId] = level
                    Task { await FriendAlerts.process(entries: store.friends) }
                } label: {
                    Label(level.title, systemImage: current == level ? "checkmark" : level.icon)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: current.icon).font(.system(size: 12, weight: .semibold))
                Text(current.shortTitle).font(.system(size: 14, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .foregroundStyle(ArcTheme.action)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(ArcTheme.action.opacity(0.12), in: Capsule())
        }
    }

    // MARK: Actions

    private var removalBinding: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }

    private func reload() {
        groups = FriendGroups.all()
        levels = Dictionary(store.friends.map { ($0.id, FriendAlerts.level(for: $0.id)) },
                            uniquingKeysWith: { a, _ in a })
    }

    private func remove(_ entry: FriendsStore.FriendEntry) {
        pendingRemoval = nil
        Task {
            do {
                try await ArcSupabase.shared.removeFriendship(with: entry.id)
                // Only once the server agreed. Swept unconditionally, a failed
                // removal brought the friend straight back into the list —
                // silently gone from every group they were in.
                FriendGroups.removeMemberEverywhere(entry.id)
                await store.refresh(force: true)
            } catch {
                store.lastError = "Couldn't remove \(entry.user.display_name) — check your connection and try again."
            }
            reload()
        }
    }
}

/// Name a group, choose who's in it, and set one notification level for all of
/// them at once — the reason groups exist rather than being a pure filter.
struct GroupEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var group: FriendGroup
    let friends: [FriendsStore.FriendEntry]
    let onSave: (FriendGroup) -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirm = false
    /// Levels mirrored into view state. `FriendAlerts` stores them in
    /// UserDefaults, which SwiftUI cannot observe — without this, tapping a
    /// level changed the setting but the tick never moved.
    @State private var levels: [String: FriendNotificationLevel] = [:]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Group name", text: $group.name)
                        .font(.system(size: 16, weight: .semibold))
                }

                Section {
                    ForEach(FriendNotificationLevel.allCases) { level in
                        Button {
                            applyToAll(level)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: level.icon)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(ArcTheme.action).frame(width: 22)
                                Text(level.title).font(.system(size: 15)).foregroundStyle(.primary)
                                Spacer()
                                if allMembersAt(level) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(ArcTheme.action)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(activeMemberIds.isEmpty)
                    }
                } header: {
                    Text("Notifications for everyone in this group")
                } footer: {
                    Text("Applies to all members now. You can still change any one person individually afterwards.")
                }

                Section("Members") {
                    ForEach(friends) { entry in
                        Button { toggle(entry.id) } label: {
                            HStack(spacing: 12) {
                                FriendAvatar(name: entry.user.display_name, size: 32,
                                             avatarURL: entry.user.avatar_url)
                                Text(entry.user.display_name)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: group.memberIds.contains(entry.id)
                                        ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 20))
                                    .foregroundStyle(group.memberIds.contains(entry.id)
                                                     ? ArcTheme.action : Color(.tertiaryLabel))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Text("Delete Group").frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle(group.name.isEmpty ? "New Group" : group.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if group.name.trimmingCharacters(in: .whitespaces).isEmpty { group.name = "Untitled" }
                        onSave(group)
                        dismiss()
                    }
                    .font(.system(size: 16, weight: .semibold))
                }
            }
            .confirmationDialog("Delete this group?", isPresented: $showDeleteConfirm) {
                Button("Delete Group", role: .destructive) { onDelete(); dismiss() }
            } message: {
                Text("The people in it stay your friends — only the grouping goes away.")
            }
        }
    }

    private func toggle(_ id: String) {
        if group.memberIds.contains(id) { group.memberIds.remove(id) } else { group.memberIds.insert(id) }
    }

    /// Members who are still actually friends. A group can outlive a
    /// friendship — groups are local, friendships are not, so one removed on
    /// another device leaves an id here that matches nobody. Counting and
    /// applying both work off this so the row count and the ticked level
    /// always describe the same people.
    private var activeMemberIds: [String] {
        friends.map(\.id).filter { group.memberIds.contains($0) }
    }

    private func level(for id: String) -> FriendNotificationLevel {
        levels[id] ?? FriendAlerts.level(for: id)
    }

    /// Ticked only when the whole group agrees — a mixed group shows no tick,
    /// which is honest: there is no single level to show.
    private func allMembersAt(_ level: FriendNotificationLevel) -> Bool {
        !activeMemberIds.isEmpty && activeMemberIds.allSatisfy { self.level(for: $0) == level }
    }

    private func applyToAll(_ level: FriendNotificationLevel) {
        for id in activeMemberIds {
            FriendAlerts.setLevel(level, for: id)
            levels[id] = level
        }
        Task { await FriendAlerts.process(entries: FriendsStore.shared.friends) }
    }
}
