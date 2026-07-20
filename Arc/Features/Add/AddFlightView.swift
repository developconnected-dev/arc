import SwiftUI
import SwiftData

/// Flighty-parity Add Flight flow: search (airline/airport/flight) → number → date → result.
/// Also offers a fully offline manual-entry path — the only reliable way to log
/// a *past* flight (live status APIs don't carry historical data), and the
/// fallback whenever live search isn't configured or comes back empty.
struct AddFlightView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Flight.scheduledDeparture) private var allFlights: [Flight]

    enum Step { case search, number, date, results, manual }

    @State private var step: Step = .search
    @State private var query = ""
    @State private var airline: AirlineRef?
    @State private var number = ""
    @State private var date = Date.now
    @State private var results: [FlightAPIClient.FlightSearchResult] = []
    @State private var isSearching = false
    @State private var errorText: String?
    @State private var isAdding = false
    @State private var addError: String?

    // Manual entry state
    @State private var manualNumber = ""
    @State private var manualDep: AirportRef?
    @State private var manualArr: AirportRef?
    @State private var manualDepartureDate = Date.now
    @State private var manualArrivalDate = Date.now.addingTimeInterval(2 * 3600)
    @State private var manualStatus: FlightStatus = .scheduled
    @State private var manualStatusTouched = false
    @State private var manualAircraft = ""
    @State private var manualRegistration = ""
    @State private var activeAirportField: AirportFieldKind?
    @State private var airportQuery = ""
    /// Which step "back" should return to from manual entry — tracked explicitly
    /// since manual entry is reachable from three different steps.
    @State private var manualReturnStep: Step = .search

    enum AirportFieldKind { case from, to }

    var initialQuery: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            ScrollView { content.padding(.bottom, 40) }
            Spacer(minLength: 0)
        }
        .background(Color(.systemBackground))
        .onAppear {
            if let q = initialQuery, query.isEmpty { query = q }
            applyDebugHooks()
        }
    }

    /// Test-only launch-argument hooks for headless screenshot verification.
    private func applyDebugHooks() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-addStep"), i + 1 < args.count else { return }
        switch args[i + 1] {
        case "manual":
            airline = ReferenceData.shared.airline("LX")
            number = "1413"
            enterManual(prefillingFrom: Date.now.addingTimeInterval(-49 * 86400))
        case "manualFilled":
            airline = ReferenceData.shared.airline("LX")
            number = "1413"
            enterManual(prefillingFrom: Date.now.addingTimeInterval(-49 * 86400))
            manualDep = ReferenceData.shared.airport("ZRH")
            manualArr = ReferenceData.shared.airport("JFK")
            manualAircraft = "Airbus A330-300"
            manualRegistration = "HB-JHQ"
        case "manualPickerOpen":
            airline = ReferenceData.shared.airline("LX")
            number = "1413"
            enterManual(prefillingFrom: .now)
            activeAirportField = .to
            airportQuery = "ath"
        case "date":
            airline = ReferenceData.shared.airline("LX")
            number = "1413"
            step = .date
        case "manualSubmit":
            // End-to-end proof: fill the form exactly as a user would, then submit.
            airline = ReferenceData.shared.airline("LX")
            number = "1413"
            enterManual(prefillingFrom: Date.now.addingTimeInterval(-49 * 86400))
            manualDep = ReferenceData.shared.airport("ZRH")
            manualArr = ReferenceData.shared.airport("JFK")
            manualAircraft = "Airbus A330-300"
            manualRegistration = "HB-JHQ"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { addManual() }
        case "liveSearchAndAdd":
            // Real end-to-end proof of the reported bug: real search against the
            // live backend, then add() through the exact path a tap would take —
            // no synthetic data anywhere in this path.
            airline = ReferenceData.shared.airline("LX")
            number = "8"
            date = .now
            step = .results
            Task {
                await runSearch()
                if let first = results.first { add(first) }
            }
        default: break
        }
    }

    // MARK: Header

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Add Flight").font(.system(size: 32, weight: .heavy))
                Spacer()
                if step != .search {
                    Button { back() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.secondary).frame(width: 34, height: 34)
                            .background(Color(.secondarySystemFill), in: Circle())
                    }.buttonStyle(.plain)
                }
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
        case .manual: "Enter the flight details yourself"
        }
    }

    private func back() {
        switch step {
        case .number: step = .search
        case .date: step = .number
        case .results: step = .date
        case .manual: step = manualReturnStep
        case .search: break
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch step {
        case .search: searchStep
        case .number: numberStep
        case .date: dateStep
        case .results: resultsStep
        case .manual: manualStep
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

            Button { enterManual(prefillingFrom: nil) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.pencil").font(.system(size: 15, weight: .semibold))
                    Text("Can't find it? Enter a flight manually")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(ArcTheme.action)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20).padding(.top, 16)
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

            Divider().padding(.horizontal, 20).padding(.top, 4)

            Button { enterManual(prefillingFrom: date, returningTo: .date) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.pencil").font(.system(size: 15, weight: .semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Adding a past flight?").font(.system(size: 15, weight: .semibold))
                        Text("Live search only covers current schedules — enter it manually instead.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .foregroundStyle(ArcTheme.action)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20).padding(.top, 4)
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
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Couldn't find that flight").font(.system(size: 16, weight: .semibold))
                        Text(errorText).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Button { enterManual(prefillingFrom: date, returningTo: .results) } label: {
                        HStack {
                            Image(systemName: "square.and.pencil")
                            Text("Enter Flight Details Manually").font(.system(size: 16, weight: .semibold))
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(ArcTheme.action, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                }.padding(20)
            } else {
                if let addError {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ArcTheme.late)
                        Text(addError).font(.system(size: 13)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(14)
                    .background(ArcTheme.late.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 20)
                }
                LazyVStack(spacing: 0) {
                    ForEach(results, id: \.flight_number) { r in
                        Button { add(r) } label: { resultCard(r) }
                            .buttonStyle(.plain)
                            .disabled(isAdding)
                            .opacity(isAdding ? 0.5 : 1)
                            .overlay(alignment: .trailing) {
                                if isAdding { ProgressView().padding(.trailing, 20) }
                            }
                        Divider().padding(.leading, 20)
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

    // MARK: Step 5 — manual entry

    private func enterManual(prefillingFrom pickedDate: Date?, returningTo: Step = .search) {
        manualReturnStep = returningTo
        addError = nil
        if manualNumber.isEmpty {
            manualNumber = "\(airline?.iata ?? "")\(number)"
        }
        if let pickedDate {
            let cal = Calendar.current
            let time = cal.dateComponents([.hour, .minute], from: manualDepartureDate)
            var merged = cal.dateComponents([.year, .month, .day], from: pickedDate)
            merged.hour = time.hour; merged.minute = time.minute
            manualDepartureDate = cal.date(from: merged) ?? pickedDate
            manualArrivalDate = manualDepartureDate.addingTimeInterval(2 * 3600)
        }
        if !manualStatusTouched {
            manualStatus = manualDepartureDate < .now ? .landed : .scheduled
        }
        step = .manual
    }

    private var manualStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("FLIGHT NUMBER").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                TextField("e.g. LX1413", text: $manualNumber)
                    .font(.system(size: 17, weight: .semibold))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .padding(14)
                    .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
            }

            HStack(spacing: 12) {
                AirportField(
                    title: "FROM", airport: manualDep, isActive: activeAirportField == .from,
                    query: $airportQuery,
                    onActivate: { activate(.from) },
                    onSelect: { a in manualDep = a; activeAirportField = nil; airportQuery = "" }
                )
                AirportField(
                    title: "TO", airport: manualArr, isActive: activeAirportField == .to,
                    query: $airportQuery,
                    onActivate: { activate(.to) },
                    onSelect: { a in manualArr = a; activeAirportField = nil; airportQuery = "" }
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                dateTimeRow(label: "DEPARTS", date: $manualDepartureDate) { new in
                    if manualArrivalDate < new { manualArrivalDate = new.addingTimeInterval(2 * 3600) }
                    if !manualStatusTouched { manualStatus = new < .now ? .landed : .scheduled }
                }
                dateTimeRow(label: "ARRIVES", date: $manualArrivalDate, onChange: nil)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("STATUS").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Picker("Status", selection: Binding(
                    get: { manualStatus },
                    set: { manualStatus = $0; manualStatusTouched = true }
                )) {
                    Text("Scheduled").tag(FlightStatus.scheduled)
                    Text("Landed").tag(FlightStatus.landed)
                    Text("Cancelled").tag(FlightStatus.cancelled)
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("AIRCRAFT (OPTIONAL)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                TextField("e.g. Airbus A320neo", text: $manualAircraft)
                    .padding(12).background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                TextField("Registration, e.g. HB-JCA", text: $manualRegistration)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .padding(12).background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))
            }

            if let addError {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ArcTheme.late)
                    Text(addError).font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(14)
                .background(ArcTheme.late.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }

            Button(action: addManual) {
                HStack {
                    Spacer()
                    Text("Add Flight").font(.system(size: 17, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(16)
                .background(canAddManual ? ArcTheme.action : Color(.systemGray4), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(!canAddManual)
        }
        .padding(.horizontal, 20).padding(.top, 4)
    }

    private func activate(_ field: AirportFieldKind) {
        activeAirportField = (activeAirportField == field) ? nil : field
        airportQuery = ""
    }

    private func dateTimeRow(label: String, date: Binding<Date>, onChange: ((Date) -> Void)?) -> some View {
        HStack {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            DatePicker("", selection: date, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .onChange(of: date.wrappedValue) { _, new in onChange?(new) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
    }

    private var canAddManual: Bool {
        guard let dep = manualDep, let arr = manualArr, dep.iata != arr.iata else { return false }
        return !manualNumber.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func addManual() {
        guard let dep = manualDep, let arr = manualArr else { return }
        // The DatePicker edits using the device's own calendar/timezone, but the rest
        // of the app treats every flight time as local-to-the-airport (see
        // `depTimeLocal`/`arrTimeLocal`) — re-project onto each airport's zone so a
        // flight entered while travelling records the right instant.
        let departure = DateHelpers.reinterpretWallClock(manualDepartureDate, asLocalTo: ReferenceData.shared.timezone(dep.iata))
        let arrival = DateHelpers.reinterpretWallClock(manualArrivalDate, asLocalTo: ReferenceData.shared.timezone(arr.iata))

        let f = Flight(flightNumber: manualNumber.uppercased(), date: departure)
        let iata = String(manualNumber.uppercased().prefix(2))
        f.airline = airline?.name ?? ReferenceData.shared.airline(iata)?.name ?? iata
        f.airlineICAO = airline?.icao ?? ReferenceData.shared.airline(iata)?.icao ?? ""
        f.departureIATA = dep.iata; f.arrivalIATA = arr.iata
        f.departureCity = dep.city; f.arrivalCity = arr.city
        f.departureLat = dep.lat; f.departureLon = dep.lon
        f.arrivalLat = arr.lat; f.arrivalLon = arr.lon
        f.scheduledDeparture = departure
        f.scheduledArrival = arrival
        f.statusRaw = manualStatus.rawValue
        if manualStatus == .landed {
            f.actualDeparture = departure
            f.actualArrival = arrival
        }
        let aircraft = manualAircraft.trimmingCharacters(in: .whitespaces)
        let reg = manualRegistration.trimmingCharacters(in: .whitespaces)
        f.aircraftType = aircraft.isEmpty ? nil : aircraft
        f.aircraftRegistration = reg.isEmpty ? nil : reg

        modelContext.insert(f)
        do {
            try modelContext.save()
            if manualStatus == .scheduled { ArcNotifications.scheduleDepartureReminder(for: f) }
            syncToCloud(f)
            dismiss()
        } catch {
            modelContext.delete(f)
            addError = "Couldn't save this flight: \(error.localizedDescription)"
        }
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
        guard let d = DateHelpers.parseAPIDate(iso) else { return "" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
    private func countdownValue(_ r: FlightAPIClient.FlightSearchResult) -> String {
        guard let d = DateHelpers.parseAPIDate(r.dep_scheduled) else { return "—" }
        let s = Int(d.timeIntervalSince(.now)); let days = s/86400; let hrs = s/3600
        return days >= 1 ? "\(days)" : "\(max(0, hrs))"
    }
    private func countdownUnit(_ r: FlightAPIClient.FlightSearchResult) -> String {
        guard let d = DateHelpers.parseAPIDate(r.dep_scheduled) else { return "" }
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
            if results.isEmpty { errorText = "No live schedule found for \(code) on \(dateChipText)." }
        } catch {
            errorText = "Live search isn't set up yet (no AeroDataBox key configured in the backend). You can still add this flight yourself below."
        }
        isSearching = false
    }

    private func add(_ r: FlightAPIClient.FlightSearchResult) {
        guard !isAdding else { return }
        isAdding = true
        addError = nil

        let departure = DateHelpers.parseAPIDate(r.dep_scheduled) ?? date
        let arrival = DateHelpers.parseAPIDate(r.arr_scheduled) ?? departure.addingTimeInterval(2 * 3600)

        let f = Flight(flightNumber: r.flight_number, date: departure)
        f.airline = r.airline_name
        f.airlineICAO = r.airline_iata
        f.departureIATA = r.dep_iata; f.arrivalIATA = r.arr_iata
        f.departureCity = r.dep_city ?? ReferenceData.shared.airport(r.dep_iata)?.city ?? r.dep_iata
        f.arrivalCity = r.arr_city ?? ReferenceData.shared.airport(r.arr_iata)?.city ?? r.arr_iata
        let dep = ReferenceData.shared.airport(r.dep_iata); let arr = ReferenceData.shared.airport(r.arr_iata)
        f.departureLat = r.dep_lat ?? dep?.lat ?? 0; f.departureLon = r.dep_lon ?? dep?.lon ?? 0
        f.arrivalLat = r.arr_lat ?? arr?.lat ?? 0; f.arrivalLon = r.arr_lon ?? arr?.lon ?? 0
        f.scheduledDeparture = departure; f.scheduledArrival = arrival
        f.statusRaw = FlightStatus.heal(rawValue: r.status, scheduledArrival: arrival).rawValue
        f.delayMinutes = r.delay ?? 0
        f.departureGate = r.dep_gate; f.departureTerminal = r.dep_terminal
        f.arrivalGate = r.arr_gate; f.arrivalTerminal = r.arr_terminal; f.baggageClaim = r.arr_baggage
        f.aircraftType = r.aircraft_type; f.aircraftRegistration = r.aircraft_registration

        modelContext.insert(f)
        do {
            try modelContext.save()
            ArcNotifications.scheduleDepartureReminder(for: f)
            syncToCloud(f)
            isAdding = false
            dismiss()
        } catch {
            modelContext.delete(f)
            isAdding = false
            addError = "Couldn't save this flight: \(error.localizedDescription)"
        }
    }

    /// Best-effort background mirror to Supabase — never blocks or fails the
    /// local add, which must keep working fully offline / signed-out.
    private func syncToCloud(_ flight: Flight) {
        Task { try? await ArcSupabase.shared.upsertUserFlight(flight) }
    }
}

// MARK: - Airport picker field (manual entry)

private struct AirportField: View {
    let title: String
    let airport: AirportRef?
    let isActive: Bool
    @Binding var query: String
    var onActivate: () -> Void
    var onSelect: (AirportRef) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onActivate) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: isActive ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    if let airport {
                        Text(airport.iata).font(.system(size: 20, weight: .bold)).foregroundStyle(.primary)
                        Text(airport.city).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text("Select").font(.system(size: 20, weight: .bold)).foregroundStyle(.tertiary)
                        Text(" ").font(.system(size: 12))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            if isActive {
                VStack(alignment: .leading, spacing: 0) {
                    TextField("City or code", text: $query)
                        .font(.system(size: 14))
                        .autocorrectionDisabled()
                        .padding(10)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 6)
                    ForEach(ReferenceData.shared.searchAirports(query, limit: 5), id: \.iata) { a in
                        Button { onSelect(a) } label: {
                            HStack(spacing: 6) {
                                Text(TextHelpers.flag(a.country)).font(.system(size: 16))
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(a.iata).font(.system(size: 13, weight: .bold))
                                    Text(a.city).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
