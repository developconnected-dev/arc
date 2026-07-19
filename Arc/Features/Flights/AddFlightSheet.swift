import SwiftUI
import SwiftData

struct AddFlightSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var selectedDate = Date.now
    @State private var isSearching = false
    @State private var searchResults: [FlightAPIClient.FlightSearchResult] = []
    @State private var errorMessage: String?
    @State private var showDatePicker = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Add Flight")
                            .font(.system(size: 28, weight: .bold))
                        Text("Enter airline, airport, or flight")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)

                // Search field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("EasyJet, HAM, or U2123", text: $searchText)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await searchFlight() } }

                    if isSearching {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 20)

                // Date row
                HStack {
                    Text("Date")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    DatePicker("", selection: $selectedDate, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                if let error = errorMessage {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                }

                // Results
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(searchResults, id: \.flight_number) { result in
                            Button { addFlight(result) } label: {
                                searchResultRow(result)
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 20)
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .onChange(of: searchText) {
                if searchText.count >= 3 {
                    Task { await searchFlight() }
                } else {
                    searchResults = []
                    errorMessage = nil
                }
            }
        }
    }

    private func searchResultRow(_ result: FlightAPIClient.FlightSearchResult) -> some View {
        HStack(spacing: 14) {
            // Airline icon placeholder
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.blue.opacity(0.1))
                .frame(width: 40, height: 40)
                .overlay(
                    Text(String(result.airline_iata.prefix(2)))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.blue)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("\(result.airline_name) \(result.flight_number)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("\(result.dep_iata) → \(result.arr_iata)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "arrow.right.circle")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func searchFlight() async {
        let query = searchText.trimmingCharacters(in: .whitespaces).uppercased()
        guard query.count >= 3 else { return }

        isSearching = true
        errorMessage = nil

        let dateStr = selectedDate.formatted(.iso8601.year().month().day())

        do {
            searchResults = try await FlightAPIClient.shared.searchFlight(number: query, date: dateStr)
            if searchResults.isEmpty {
                errorMessage = "No flights found for \(query)"
            }
        } catch {
            errorMessage = "Could not search. Check your connection and backend URL in Settings."
        }

        isSearching = false
    }

    private func addFlight(_ result: FlightAPIClient.FlightSearchResult) {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dfFallback = ISO8601DateFormatter()
        dfFallback.formatOptions = [.withInternetDateTime]

        func parseDate(_ str: String) -> Date {
            df.date(from: str) ?? dfFallback.date(from: str) ?? selectedDate
        }

        let flight = Flight(flightNumber: result.flight_number, date: parseDate(result.dep_scheduled))
        flight.airline = result.airline_name
        flight.airlineICAO = result.airline_iata
        flight.departureIATA = result.dep_iata
        flight.arrivalIATA = result.arr_iata
        flight.departureCity = result.dep_city ?? result.dep_iata
        flight.arrivalCity = result.arr_city ?? result.arr_iata

        let depCoords = AirportDatabase.coordinates(for: result.dep_iata)
        let arrCoords = AirportDatabase.coordinates(for: result.arr_iata)
        flight.departureLat = result.dep_lat ?? depCoords.lat
        flight.departureLon = result.dep_lon ?? depCoords.lon
        flight.arrivalLat = result.arr_lat ?? arrCoords.lat
        flight.arrivalLon = result.arr_lon ?? arrCoords.lon

        if flight.departureCity == flight.departureIATA, let dep = AirportDatabase.lookup(result.dep_iata) {
            flight.departureCity = dep.city
        }
        if flight.arrivalCity == flight.arrivalIATA, let arr = AirportDatabase.lookup(result.arr_iata) {
            flight.arrivalCity = arr.city
        }

        flight.scheduledDeparture = parseDate(result.dep_scheduled)
        flight.scheduledArrival = parseDate(result.arr_scheduled)
        flight.statusRaw = result.status
        flight.delayMinutes = result.delay ?? 0
        flight.departureGate = result.dep_gate
        flight.departureTerminal = result.dep_terminal
        flight.arrivalGate = result.arr_gate
        flight.arrivalTerminal = result.arr_terminal
        flight.baggageClaim = result.arr_baggage
        flight.aircraftType = result.aircraft_type
        flight.aircraftRegistration = result.aircraft_registration

        modelContext.insert(flight)
        try? modelContext.save()

        ArcNotifications.scheduleDepartureReminder(for: flight)
        dismiss()
    }
}
