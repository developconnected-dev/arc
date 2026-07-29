import Foundation

/// One of the user's own groupings of their friends — "Family", "Close friends".
///
/// Local to the device, exactly like `FriendNotificationLevel`: a group records
/// how YOU want your feed organised and how loudly these people may interrupt
/// you. None of it is visible to the friends themselves, so it never needs to
/// round-trip through Supabase.
struct FriendGroup: Codable, Identifiable, Equatable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    /// `ArcUser.id` — the same key `FriendAlerts` stores levels under, so a
    /// group can set the level for everyone in it without a second mapping.
    var memberIds: Set<String> = []
}

@MainActor
enum FriendGroups {
    private static let storageKey = "friendGroups"

    static func all() -> [FriendGroup] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let groups = try? JSONDecoder().decode([FriendGroup].self, from: data)
        else { return [] }
        return groups
    }

    static func save(_ groups: [FriendGroup]) {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func upsert(_ group: FriendGroup) {
        var groups = all()
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
        } else {
            groups.append(group)
        }
        save(groups)
    }

    static func delete(_ id: String) {
        save(all().filter { $0.id != id })
    }

    /// Removing a friendship has to drop that person from every group too —
    /// otherwise a group keeps a member who is no longer a friend, and the
    /// feed filter silently returns fewer people than the group claims.
    nonisolated static func pruning(_ userId: String, from groups: [FriendGroup]) -> [FriendGroup] {
        groups.map { group in
            var pruned = group
            pruned.memberIds.remove(userId)
            return pruned
        }
    }

    static func removeMemberEverywhere(_ userId: String) {
        save(pruning(userId, from: all()))
    }
}
