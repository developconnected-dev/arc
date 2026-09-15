import SwiftUI

/// The three tabs. The bar itself is now a native `TabView` in `ArcRootView`,
/// so this is just the model: the system draws the Liquid Glass chrome, and the
/// hand-rolled capsule that used to live here is gone.
enum ArcTab: CaseIterable {
    case myFlights, friends, passport
    // The case name stays `myFlights`: it is referenced across the tab bar,
    // root view and deep links, and the parallel rename buys nothing the title
    // doesn't already give.
    var title: String { switch self { case .myFlights: "My Trips"; case .friends: "Friends"; case .passport: "Passport" } }
    var icon: String { switch self { case .myFlights: "airplane"; case .friends: "person.2.fill"; case .passport: "book.pages.fill" } }
}

/// What the native `TabView` selects between: the three tabs, plus the round
/// **+** bubble iOS draws beside the bar for a search-role tab. `add` is never
/// held as the selection — picking it opens the Add sheet and leaves the user
/// on the tab they were on (docs/superpowers/specs/2026-09-15-floating-trips-design.md).
enum TabSelection: Hashable {
    case tab(ArcTab)
    case add

    static let addTitle = "Add a trip"
    static let addIcon = "plus"
}
