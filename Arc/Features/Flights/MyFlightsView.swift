import SwiftUI
import SwiftData

/// The My Flights sheet content: title + share/avatar, then active & upcoming
/// flights as countdown cards. Past flights live in Passport.
struct MyFlightsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Flight.scheduledDeparture) private var allFlights: [Flight]
    var onSelect: (Flight) -> Void

    @State private var showSettings = false

    private var flights: [Flight] {
        allFlights
            .filter { $0.isActive || $0.isUpcoming }
            .sorted { a, b in
                if a.isActive != b.isActive { return a.isActive && !b.isActive }
                return a.scheduledDeparture < b.scheduledDeparture
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 0) {
                    if flights.isEmpty {
                        emptyState.padding(.top, 40)
                    } else {
                        ForEach(Array(flights.enumerated()), id: \.element.id) { idx, flight in
                            Button { onSelect(flight) } label: { FlightRowCard(flight: flight) }
                                .buttonStyle(.plain)
                            if idx < flights.count - 1 {
                                Divider().padding(.leading, 20)
                            }
                        }
                    }
                }
                .padding(.bottom, 140)   // clear the floating pill
            }
            .scrollIndicators(.hidden)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("My Flights").font(ArcTheme.screenTitle)
            Spacer()
            ShareLink(item: URL(string: "https://arc.flight")!) {
                circleIcon("square.and.arrow.up")
            }
            Button { showSettings = true } label: {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color(.systemGray3), Color(.systemGray5))
            }
            .buttonStyle(.plain)
        }
    }

    private func circleIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 36, height: 36)
            .background(Color(.secondarySystemFill), in: Circle())
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "airplane.departure")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("No upcoming flights")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Tap the search button to add a flight.")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}
