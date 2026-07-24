import SwiftUI
import SwiftData

/// The My Flights sheet content: title + share/avatar, then active & upcoming
/// flights as countdown cards. A flight stays here for 30 minutes after
/// landing too (arrival gate, baggage claim still visible) before moving
/// exclusively to Passport history.
struct MyFlightsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Flight.scheduledDeparture) private var allFlights: [Flight]
    var onSelect: (Flight) -> Void

    @State private var showSettings = false

    private var flights: [Flight] {
        allFlights
            .filter { $0.isActive || $0.isUpcoming || $0.isRecentlyLanded }
            .sorted { a, b in
                // Active and recently-landed are the most time-sensitive —
                // keep them pinned above the upcoming-by-soonest ordering.
                let aRank = a.isActive ? 0 : (a.isRecentlyLanded ? 1 : 2)
                let bRank = b.isActive ? 0 : (b.isRecentlyLanded ? 1 : 2)
                if aRank != bRank { return aRank < bRank }
                if aRank == 1 {
                    return (a.actualArrival ?? a.scheduledArrival) > (b.actualArrival ?? b.scheduledArrival)
                }
                return a.scheduledDeparture < b.scheduledDeparture
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 10)

            List {
                if flights.isEmpty {
                    emptyState.padding(.top, 40)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                } else {
                    ForEach(Array(flights.enumerated()), id: \.element.id) { idx, flight in
                        Button { onSelect(flight) } label: { FlightRowCard(flight: flight) }
                            .buttonStyle(.plain)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { delete(flight) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .overlay(alignment: .bottom) {
                                if idx < flights.count - 1 {
                                    Divider().padding(.leading, 20)
                                }
                            }
                    }
                }
                Color.clear.frame(height: 140)   // clear the floating pill
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-openSettings") { showSettings = true }
        }
    }

    private func delete(_ flight: Flight) {
        // Capture before delete — the model becomes invalid after.
        let id = flight.id
        let number = flight.flightNumber
        let departure = flight.scheduledDeparture
        ArcNotifications.removeAll(for: flight)
        modelContext.delete(flight)
        try? modelContext.save()
        Task {
            try? await ArcSupabase.shared.deleteUserFlight(id: id)
            try? await ArcSupabase.shared.unshareFlight(flightNumber: number, scheduledDeparture: departure)
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
