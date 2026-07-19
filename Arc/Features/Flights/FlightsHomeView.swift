import SwiftUI
import SwiftData

struct FlightsHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Flight.scheduledDeparture) private var allFlights: [Flight]
    @ObservedObject private var tracker = FlightTracker.shared

    @State private var showingAddFlight = false
    @State private var flightToDelete: Flight?
    @State private var showDeleteConfirmation = false

    private var upcomingFlights: [Flight] { allFlights.filter(\.isUpcoming) }
    private var activeFlights: [Flight] { allFlights.filter(\.isActive) }
    private var pastFlights: [Flight] { allFlights.filter(\.isCompleted).reversed() }

    var body: some View {
        NavigationStack {
            ZStack {
                // Full-screen shared map background (temporary; rebuilt in My Flights plan)
                ArcMapView(flights: allFlights, controller: MapController())
                    .ignoresSafeArea()

                // Bottom sheet content
                VStack(spacing: 0) {
                    Spacer()

                    VStack(spacing: 0) {
                        // Drag handle
                        Capsule()
                            .fill(Color.secondary.opacity(0.3))
                            .frame(width: 36, height: 5)
                            .padding(.top, 8)
                            .padding(.bottom, 12)

                        // Title row
                        HStack {
                            Text("My Flights")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(.primary)
                            Spacer()
                            Button { showingAddFlight = true } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 28))
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(.blue)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)

                        ScrollView {
                            VStack(spacing: 12) {
                                if !activeFlights.isEmpty {
                                    ForEach(activeFlights) { flight in
                                        NavigationLink(value: flight) {
                                            flightRow(flight)
                                        }
                                    }
                                }

                                if !upcomingFlights.isEmpty {
                                    ForEach(upcomingFlights) { flight in
                                        NavigationLink(value: flight) {
                                            flightRow(flight)
                                        }
                                    }
                                }

                                if !pastFlights.isEmpty {
                                    sectionHeader("Past")
                                    ForEach(pastFlights.prefix(10)) { flight in
                                        NavigationLink(value: flight) {
                                            flightRow(flight)
                                        }
                                    }
                                }

                                if allFlights.isEmpty {
                                    VStack(spacing: 12) {
                                        Spacer().frame(height: 20)
                                        Image(systemName: "airplane.circle")
                                            .font(.system(size: 48))
                                            .foregroundStyle(.tertiary)
                                        Text("No flights yet")
                                            .font(.system(size: 17, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                        Text("Tap + to add your first flight")
                                            .font(.system(size: 14))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 100)
                        }
                        .refreshable { await refreshFlights() }
                    }
                    .frame(maxHeight: UIScreen.main.bounds.height * 0.45)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(.regularMaterial)
                            .ignoresSafeArea(edges: .bottom)
                    )
                }
            }
            .sheet(isPresented: $showingAddFlight) {
                AddFlightSheet()
                    .presentationDetents([.medium, .large])
            }
            .navigationDestination(for: Flight.self) { flight in
                FlightDetailView(flight: flight)
            }
            .confirmationDialog(
                "Delete this flight?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let flight = flightToDelete { deleteFlight(flight) }
                }
                Button("Cancel", role: .cancel) { flightToDelete = nil }
            } message: {
                if let flight = flightToDelete {
                    Text("\(flight.flightNumber) — \(flight.departureIATA) → \(flight.arrivalIATA)")
                }
            }
            .onAppear {
                tracker.startTracking(flights: allFlights, modelContext: modelContext)
                WidgetSync.sync(flights: allFlights)
            }
            .onChange(of: allFlights.count) {
                tracker.startTracking(flights: allFlights, modelContext: modelContext)
                WidgetSync.sync(flights: allFlights)
            }
            .toolbarVisibility(.hidden, for: .navigationBar)
        }
    }

    // MARK: - Flight Row

    private func flightRow(_ flight: Flight) -> some View {
        FlightCard(flight: flight)
            .contextMenu {
                Button(role: .destructive) {
                    flightToDelete = flight
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete Flight", systemImage: "trash")
                }
            }
    }

    // MARK: - Actions

    private func deleteFlight(_ flight: Flight) {
        ArcNotifications.removeAll(for: flight)
        modelContext.delete(flight)
        try? modelContext.save()
        flightToDelete = nil
    }

    private func refreshFlights() async {
        for flight in allFlights where flight.isActive || flight.isUpcoming {
            let dateStr = flight.scheduledDeparture.formatted(.iso8601.year().month().day())
            do {
                let results = try await FlightAPIClient.shared.searchFlight(
                    number: flight.flightNumber, date: dateStr
                )
                guard let latest = results.first else { continue }
                flight.statusRaw = latest.status
                flight.delayMinutes = latest.delay ?? 0
                if let gate = latest.dep_gate, !gate.isEmpty { flight.departureGate = gate }
                if let terminal = latest.dep_terminal, !terminal.isEmpty { flight.departureTerminal = terminal }
                if let gate = latest.arr_gate, !gate.isEmpty { flight.arrivalGate = gate }
                if let terminal = latest.arr_terminal, !terminal.isEmpty { flight.arrivalTerminal = terminal }
                if let baggage = latest.arr_baggage, !baggage.isEmpty { flight.baggageClaim = baggage }
            } catch { continue }
        }
        try? modelContext.save()
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textCase(.uppercase)
            .tracking(0.8)
    }
}
