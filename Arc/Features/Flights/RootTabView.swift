import SwiftUI

struct RootTabView: View {
    @State private var showingSearch = false

    var body: some View {
        TabView {
            Tab("My Flights", systemImage: "airplane") {
                FlightsHomeView()
            }

            Tab("Friends", systemImage: "person.2.fill") {
                FriendsTabView()
            }

            Tab("Passport", systemImage: "globe.americas.fill") {
                PassportStatsView()
            }

            Tab("Search", systemImage: "magnifyingglass") {
                AddFlightSheet()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}
