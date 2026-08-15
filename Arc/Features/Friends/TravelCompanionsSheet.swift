import SwiftUI

/// Who is ON this trip with you — as opposed to who may see it.
///
/// Sharing (`FlightAudienceSheet`) is visibility: a friend watches your flight
/// in their feed. This is identity: the friend gets the same journey offered
/// for their own list, and on Accept it becomes theirs — tracked, in their
/// widget, in their passport. Being on the trip implies seeing it, so picking
/// a companion also lets them into the audience.
struct TravelCompanionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = FriendsStore.shared

    @Binding var travellingWithIds: [String]
    /// Already invited (answered or not) — shown ticked and locked, so the
    /// same person can't be invited twice from the detail screen.
    var lockedIds: [String] = []

    private var atCap: Bool {
        travellingWithIds.count + lockedIds.filter { !travellingWithIds.contains($0) }.count
            >= ArcSupabase.maxTripCompanions
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.friends) { entry in
                        let locked = lockedIds.contains(entry.id)
                        let on = locked || travellingWithIds.contains(entry.id)
                        Button { toggle(entry.id) } label: {
                            HStack(spacing: 12) {
                                FriendAvatar(name: entry.user.display_name, size: 32,
                                             avatarURL: entry.user.avatar_url)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.user.display_name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    if locked {
                                        Text("Already invited")
                                            .font(.system(size: 12)).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 20))
                                    .foregroundStyle(on ? ArcTheme.action : Color(.tertiaryLabel))
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(locked || (!on && atCap))
                        .opacity(!on && atCap ? 0.5 : 1)
                    }
                } header: {
                    Text("Travelling with")
                } footer: {
                    Text(atCap
                         ? "Up to \(ArcSupabase.maxTripCompanions) people per trip. For a bigger group, share it instead."
                         : "They'll get this trip offered in their own list and can accept it with one tap. Nothing is added to their trips until they do.")
                }
            }
            .navigationTitle("Travelling with")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.font(.system(size: 16, weight: .semibold))
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if let index = travellingWithIds.firstIndex(of: id) {
            travellingWithIds.remove(at: index)
        } else if !atCap {
            travellingWithIds.append(id)
        }
    }
}

/// The tappable "Travelling with · Peter" row, used by the add flow and the
/// flight detail screen alike.
struct TravelCompanionsRow: View {
    @Binding var travellingWithIds: [String]
    var lockedIds: [String] = []
    /// Runs when the picker closes — the detail screen sends its invitations
    /// here; the add flow sends them with the trip and passes nothing.
    var onDone: (() -> Void)? = nil
    @State private var store = FriendsStore.shared
    @State private var showPicker = false

    var body: some View {
        Button { showPicker = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                Text("Travelling with").font(.system(size: 15)).foregroundStyle(.primary)
                Spacer()
                Text(summary)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(travellingWithIds.isEmpty && lockedIds.isEmpty ? .secondary : ArcTheme.action)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showPicker, onDismiss: { onDone?() }) {
            TravelCompanionsSheet(travellingWithIds: $travellingWithIds, lockedIds: lockedIds)
                .presentationDetents([.medium, .large])
        }
    }

    private var summary: String {
        var ids = lockedIds
        for id in travellingWithIds where !ids.contains(id) { ids.append(id) }
        let names = ids.compactMap { id in store.friends.first { $0.id == id }?.user.display_name }
        if names.isEmpty { return "Just me" }
        if names.count <= 2 { return names.formatted(.list(type: .and)) }
        return "\(names.count) people"
    }
}
