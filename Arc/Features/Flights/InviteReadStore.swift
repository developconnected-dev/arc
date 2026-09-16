import SwiftUI

/// Which trip invites the traveller has already laid eyes on.
///
/// An invite counts as seen once the stack has flipped to it — it was on
/// screen, in front of them — and that outlives the launch it happened in, so
/// the bell's red dot means "something new", not "you still have invites".
/// Ids of invites that are gone are pruned, so the set can't grow forever.
@MainActor @Observable
final class InviteReadStore {
    static let shared = InviteReadStore()

    private static let key = "invites.seen"
    @ObservationIgnored private let defaults: UserDefaults

    private(set) var seen: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        seen = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    /// Any of these invites still unseen: what the red dot rides on.
    func hasUnread(among ids: [String]) -> Bool {
        ids.contains { !seen.contains($0) }
    }

    func markSeen(_ id: String) {
        guard !seen.contains(id) else { return }
        seen.insert(id)
        persist()
    }

    /// Forget everything that isn't an open invite any more.
    func prune(keeping ids: [String]) {
        let kept = seen.intersection(ids)
        guard kept != seen else { return }
        seen = kept
        persist()
    }

    private func persist() {
        defaults.set(Array(seen), forKey: Self.key)
    }
}
