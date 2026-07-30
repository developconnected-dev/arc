import SwiftUI

/// The three tabs. The bar itself is now a native `TabView` in `ArcRootView`,
/// so this is just the model: the system draws the Liquid Glass chrome, and the
/// hand-rolled capsule that used to live here is gone.
enum ArcTab: CaseIterable {
    case myFlights, friends, passport
    var title: String { switch self { case .myFlights: "My Flights"; case .friends: "Friends"; case .passport: "Passport" } }
    var icon: String { switch self { case .myFlights: "airplane"; case .friends: "person.2.fill"; case .passport: "book.pages.fill" } }
}
