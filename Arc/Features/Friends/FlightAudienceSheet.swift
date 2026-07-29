import SwiftUI

/// Who a single flight is shared with.
///
/// Separate from `FriendGroup` on purpose: a group is a way to *pick* people,
/// not a stored audience. Picking one resolves to its members at that moment,
/// so adding someone to "Family" later doesn't retroactively hand them a trip
/// you already shared.
enum FlightAudience {
    /// Label for the "Shared with" row. Names the group when the selection is
    /// exactly that group, so the common case reads "Family" and not "2 people".
    static func summary(ids: [String]?,
                        friends: [FriendsStore.FriendEntry],
                        groups: [FriendGroup]) -> String {
        guard let ids else { return "Everyone" }
        let known = friends.filter { ids.contains($0.id) }
        if known.isEmpty { return "No one" }
        if let group = groups.first(where: { group in
            let members = friends.filter { group.memberIds.contains($0.id) }
            return !members.isEmpty && Set(members.map(\.id)) == Set(known.map(\.id))
        }) {
            return group.name
        }
        if known.count <= 2 {
            return known.map(\.user.display_name).formatted(.list(type: .and))
        }
        return "\(known.count) people"
    }
}

struct FlightAudienceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = FriendsStore.shared
    @State private var groups: [FriendGroup] = []

    /// nil = everyone. Bound so both the add flow and flight detail edit the
    /// same value straight through.
    @Binding var sharedWithIds: [String]?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(title: "Everyone", icon: "globe.europe.africa.fill",
                        selected: sharedWithIds == nil) {
                        sharedWithIds = nil
                    }
                } footer: {
                    Text("Everyone means every friend you have now and any you add later.")
                }

                if !groups.isEmpty {
                    Section("Groups") {
                        ForEach(groups) { group in
                            let members = store.friends
                                .filter { group.memberIds.contains($0.id) }.map(\.id)
                            row(title: group.name, icon: "person.2.fill",
                                selected: !members.isEmpty && Set(selected) == Set(members)) {
                                sharedWithIds = members
                            }
                            .disabled(members.isEmpty)
                        }
                    }
                }

                Section {
                    ForEach(store.friends) { entry in
                        Button { toggle(entry.id) } label: {
                            HStack(spacing: 12) {
                                FriendAvatar(name: entry.user.display_name, size: 32,
                                             avatarURL: entry.user.avatar_url)
                                Text(entry.user.display_name)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: isOn(entry.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 20))
                                    .foregroundStyle(isOn(entry.id) ? ArcTheme.action : Color(.tertiaryLabel))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("People")
                } footer: {
                    Text(sharedWithIds?.isEmpty == true
                         ? "Nobody selected — this flight stays private."
                         : "Picking people replaces Everyone. Deselect them all to keep the flight private.")
                }
            }
            .navigationTitle("Share with")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.font(.system(size: 16, weight: .semibold))
                }
            }
        }
        .onAppear { groups = FriendGroups.all() }
    }

    /// "Everyone" has no explicit list, so treat it as nobody individually
    /// ticked — otherwise every friend would look selected and deselecting one
    /// would silently mean "all except".
    private var selected: [String] { sharedWithIds ?? [] }

    private func isOn(_ id: String) -> Bool { selected.contains(id) }

    private func toggle(_ id: String) {
        var ids = selected
        if let index = ids.firstIndex(of: id) { ids.remove(at: index) } else { ids.append(id) }
        sharedWithIds = ids
    }

    private func row(title: String, icon: String, selected: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ArcTheme.action).frame(width: 26)
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(ArcTheme.action)
                }
            }
        }.buttonStyle(.plain)
    }
}

/// The tappable "Shared with · Everyone" row used by both the add flow and the
/// flight detail screen, so the two can't drift apart.
struct FlightAudienceRow: View {
    @Binding var sharedWithIds: [String]?
    @State private var store = FriendsStore.shared
    @State private var showPicker = false

    var body: some View {
        Button { showPicker = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                Text("Shared with").font(.system(size: 15)).foregroundStyle(.primary)
                Spacer()
                Text(FlightAudience.summary(ids: sharedWithIds,
                                            friends: store.friends,
                                            groups: FriendGroups.all()))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ArcTheme.action)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showPicker) {
            FlightAudienceSheet(sharedWithIds: $sharedWithIds)
                .presentationDetents([.medium, .large])
        }
    }
}
