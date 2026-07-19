import SwiftUI
import SwiftData

/// Flighty-parity Add Flight flow: search (airline/airport/flight) → number → date → result.
struct AddFlightView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Flight.scheduledDeparture) private var allFlights: [Flight]

    enum Step { case search, number, date, results }

    @State private var step: Step = .search
    @State private var query = ""
    @State private var airline: AirlineRef?
    @State private var number = ""
    @State private var date = Date.now
    @State private var results: [FlightAPIClient.FlightSearchResult] = []
    @State private var isSearching = false
    @State private var errorText: String?

    var initialQuery: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            content
            Spacer(minLength: 0)
        }
        .background(Color(.systemBackground))
        .onAppear { if let q = initialQuery, query.isEmpty { query = q } }
    }

    // MARK: Header

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Add Flight").font(.system(size: 32, weight: .heavy))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.secondary).frame(width: 34, height: 34)
                        .background(Color(.secondarySystemFill), in: Circle())
                }.buttonStyle(.plain)
            }
            Text(subtitle).font(.system(size: 15)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 14)
    }

    private var subtitle: String {
        switch step {
        case .search: "Enter airline, airport, or flight"
        case .number: "Enter flight number"
        case .date: "Enter departure date"
        case .results: "Tap flight to add to My Flights"
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch step {
        case .search: searchStep
        case .number: numberStep
        case .date: dateStep
        case .results: resultsStep
        }
    }

    // MARK: Chips row (airline / number / date)

    private func chips() -> some View {
        HStack(spacing: 8) {
            if let airline { chip(airline.iata) }
            if step == .date || step == .results, !number.isEmpty { chip(number) }
            if step == .results { chip(dateChipText) }
        }
    }
    private func chip(_ text: String) -> some View {
        Text(text).font(.system(size: 17, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Step 1 — search

    private var searchStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField(placeholder: "EasyJet, HAM, or U2123", text: $query)
                .padding(.horizontal, 20)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if query.isEmpty {
                        listHeader("FREQUENTLY USED")
                        ForEach(frequentAirlines, id: \.iata) { a in airlineRow(a) }
                    } else {
                        if TextHelpers.looksLikeFlightNumber(query), let a = detectedAirline {
                            detectedFlightRow(a)
                        }
                        ForEach(ReferenceData.shared.searchAirlines(query), id: \.iata) { airlineRow($0) }
                        ForEach(ReferenceData.shared.searchAirports(query), id: \.iata) { airportRow($0) }
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    private var frequentAirlines: [AirlineRef] {
        let flown = allFlights.map { $0.airlineCode }
        var codes = Array(NSOrderedSet(array: flown)).compactMap { $0 as? String }
        for def in ["LX", "U2", "W6", "BA", "LH"] where !codes.contains(def) { codes.append(def) }
        return codes.compactMap { ReferenceData.shared.airline($0) }.prefix(6).map { $0 }
    }

    private var detectedAirline: AirlineRef? {
        ReferenceData.shared.airline(String(query.uppercased().prefix(2)))
    }

    private func detectedFlightRow(_ a: AirlineRef) -> some View {
        let clean = query.uppercased().replacingOccurrences(of: " ", with: "")
        return Button {
            airline = a
            number = String(clean.dropFirst(2))
            step = .date
        } label: {
            HStack(spacing: 14) {
                AirlineLogoView(iata: a.iata, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(a.name) \(clean.dropFirst(2))").font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                    Text("Detected flight number").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                arrowButton
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }.buttonStyle(.plain)
    }

    private func airlineRow(_ a: AirlineRef) -> some View {
        Button { airline = a; number = ""; step = .number } label: {
            HStack(spacing: 14) {
                AirlineLogoView(iata: a.iata, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                    (TextHelpers.highlight(a.iata, query: query, color: ArcTheme.action)
                     + Text("  •  ").foregroundColor(.secondary)
                     + TextHelpers.highlight(a.icao, query: query, color: ArcTheme.action))
                        .font(.system(size: 13, weight: .medium)).foregroundColor(.secondary)
                }
                Spacer()
                arrowButton
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }.buttonStyle(.plain)
    }

    private func airportRow(_ a: AirportRef) -> some View {
        Button { query = a.iata } label: {
            HStack(spacing: 14) {
                Text(TextHelpers.flag(a.country)).font(.system(size: 34))
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                    (TextHelpers.highlight(a.iata, query: query, color: ArcTheme.action)
                     + Text("  •  ").foregroundColor(.secondary)
                     + TextHelpers.highlight(a.icao, query: query, color: ArcTheme.action)
                     + Text("  •  \(a.city)").foregroundColor(.secondary))
                        .font(.system(size: 13, weight: .medium)).foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }.buttonStyle(.plain)
    }

    // MARK: Step 2 — number

    private var numberStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 8) {
                if let airline { chip(airline.iata) }
                searchField(placeholder: "123", text: $number, keyboard: .numberPad, submit: {
                    if !number.isEmpty { step = .date }
                })
            }
            .padding(.horizontal, 20)

            if number.isEmpty {
                tipRow(icon: "number", title: "Tip: Just The Numbers", sub: "Not including airline code")
            } else {
                Button { step = .date } label: {
                    HStack {
                        AirlineLogoView(iata: airline?.iata ?? "", size: 32)
                        Text("\(airline?.name ?? "") \(number)").font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                        Spacer()
                        arrowButton
                    }
                    .padding(.horizontal, 20)
                }.buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    // MARK: Step 3 — date

    private var dateStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            chips().padding(.horizontal, 20)
            dateOptionRow(icon: "checkmark.square", title: "Today", sub: dateString(.now)) { pick(.now) }
            dateOptionRow(icon: "plus.square", title: "Tomorrow", sub: dateString(.now.addingTimeInterval(86400))) { pick(.now.addingTimeInterval(86400)) }
            HStack(spacing: 14) {
                Image(systemName: "calendar").font(.system(size: 20)).frame(width: 40)
                DatePicker("Pick from Calendar", selection: $date, displayedComponents: .date)
                    .labelsHidden()
                Text("Pick from Calendar").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Go") { pick(date) }.font(.system(size: 15, weight: .semibold))
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 4)
    }

    private func pick(_ d: Date) { date = d; step = .results; Task { await runSearch() } }

    // MARK: Step 4 — results

    private var resultsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            chips().padding(.horizontal, 20)
            if isSearching {
                HStack { ProgressView(); Text("Searching…").foregroundStyle(.secondary) }.padding(20)
            } else if let errorText {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Couldn’t find that flight").font(.system(size: 16, weight: .semibold))
                    Text(errorText).font(.system(size: 13)).foregroundStyle(.secondary)
                }.padding(20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results, id: \.flight_number) { r in
                            Button { add(r) } label: { resultCard(r) }.buttonStyle(.plain)
                            Divider().padding(.leading, 20)
                        }
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private func resultCard(_ r: FlightAPIClient.FlightSearchResult) -> some View {
        let depCity = r.dep_city ?? ReferenceData.shared.airport(r.dep_iata)?.city ?? r.dep_iata
        let arrCity = r.arr_city ?? ReferenceData.shared.airport(r.arr_iata)?.city ?? r.arr_iata
        return HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Text(countdownValue(r)).font(.system(size: 26, weight: .heavy))
                Text(countdownUnit(r)).font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
            }.frame(width: 56)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    AirlineLogoView(iata: String(r.flight_number.prefix(2)), size: 20)
                    Text(r.flight_number).font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("Departs \(r.status.capitalized)").font(.system(size: 14, weight: .semibold)).foregroundStyle(ArcTheme.onTime)
                }
                (Text(depCity).font(.system(size: 18, weight: .bold)).foregroundColor(.primary)
                 + Text(" to ").font(.system(size: 18)).foregroundColor(.secondary)
                 + Text(arrCity).font(.system(size: 18, weight: .bold)).foregroundColor(.primary))
                HStack(spacing: 18) {
                    Text("\(r.dep_iata)  \(timeOnly(r.dep_scheduled))").font(.system(size: 14, weight: .semibold)).foregroundStyle(ArcTheme.onTime)
                    Text("\(r.arr_iata)  \(timeOnly(r.arr_scheduled))").font(.system(size: 14, weight: .semibold)).foregroundStyle(ArcTheme.onTime)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: Shared bits

    private func searchField(placeholder: String, text: Binding<String>, keyboard: UIKeyboardType = .default, submit: (() -> Void)? = nil) -> some View {
        HStack {
            TextField(placeholder, text: text)
                .font(.system(size: 17))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
                .onSubmit { submit?() }
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }.buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
    }

    private var arrowButton: some View {
        Image(systemName: "arrow.right").font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary).frame(width: 34, height: 34)
            .overlay(Circle().stroke(Color(.separator), lineWidth: 1))
    }

    private func listHeader(_ t: String) -> some View {
        Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).tracking(0.5)
            .padding(.horizontal, 20).padding(.bottom, 4)
    }

    private func tipRow(icon: String, title: String, sub: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(.secondary).frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(sub).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(.horizontal, 20)
    }

    private func dateOptionRow(icon: String, title: String, sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 22)).foregroundStyle(.primary).frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                    Text(sub).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                arrowButton
            }
            .padding(.horizontal, 20)
        }.buttonStyle(.plain)
    }

    private var dateChipText: String { dateString(date) }
    private func dateString(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEE, d MMM"
        return f.string(from: d)
    }
    private func timeOnly(_ iso: String) -> String {
        let df = ISO8601DateFormatter(); df.formatOptions = [.withInternetDateTime]
        let d = df.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let d else { return "" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
    private func countdownValue(_ r: FlightAPIClient.FlightSearchResult) -> String {
        let df = ISO8601DateFormatter(); df.formatOptions = [.withInternetDateTime]
        guard let d = df.date(from: r.dep_scheduled) else { return "—" }
        let s = Int(d.timeIntervalSince(.now)); let days = s/86400; let hrs = s/3600
        return days >= 1 ? "\(days)" : "\(max(0, hrs))"
    }
    private func countdownUnit(_ r: FlightAPIClient.FlightSearchResult) -> String {
        let df = ISO8601DateFormatter(); df.formatOptions = [.withInternetDateTime]
        guard let d = df.date(from: r.dep_scheduled) else { return "" }
        return Int(d.timeIntervalSince(.now)) >= 86400 ? "DAYS" : "HOURS"
    }

    // MARK: Actions

    private func runSearch() async {
        guard let airline else { return }
        isSearching = true; errorText = nil; results = []
        let code = "\(airline.iata)\(number)"
        let dateStr = date.formatted(.iso8601.year().month().day())
        do {
            results = try await FlightAPIClient.shared.searchFlight(number: code, date: dateStr)
            if results.isEmpty { errorText = "No flights found for \(code) on \(dateChipText)." }
        } catch {
            errorText = "Add your AeroDataBox key in Settings to search live flights."
        }
        isSearching = false
    }

    private func add(_ r: FlightAPIClient.FlightSearchResult) {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        func parse(_ s: String) -> Date { iso.date(from: s) ?? date }
        let f = Flight(flightNumber: r.flight_number, date: parse(r.dep_scheduled))
        f.airline = r.airline_name
        f.airlineICAO = r.airline_iata
        f.departureIATA = r.dep_iata; f.arrivalIATA = r.arr_iata
        f.departureCity = r.dep_city ?? ReferenceData.shared.airport(r.dep_iata)?.city ?? r.dep_iata
        f.arrivalCity = r.arr_city ?? ReferenceData.shared.airport(r.arr_iata)?.city ?? r.arr_iata
        let dep = ReferenceData.shared.airport(r.dep_iata); let arr = ReferenceData.shared.airport(r.arr_iata)
        f.departureLat = r.dep_lat ?? dep?.lat ?? 0; f.departureLon = r.dep_lon ?? dep?.lon ?? 0
        f.arrivalLat = r.arr_lat ?? arr?.lat ?? 0; f.arrivalLon = r.arr_lon ?? arr?.lon ?? 0
        f.scheduledDeparture = parse(r.dep_scheduled); f.scheduledArrival = parse(r.arr_scheduled)
        f.statusRaw = r.status; f.delayMinutes = r.delay ?? 0
        f.departureGate = r.dep_gate; f.departureTerminal = r.dep_terminal
        f.arrivalGate = r.arr_gate; f.arrivalTerminal = r.arr_terminal; f.baggageClaim = r.arr_baggage
        f.aircraftType = r.aircraft_type; f.aircraftRegistration = r.aircraft_registration
        modelContext.insert(f)
        try? modelContext.save()
        ArcNotifications.scheduleDepartureReminder(for: f)
        dismiss()
    }
}
