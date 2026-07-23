import SwiftUI
import SwiftData

struct ArcRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Flight.scheduledDeparture) private var allFlights: [Flight]
    @ObservedObject private var supabase = ArcSupabase.shared

    @State private var controller = MapController()
    @State private var tab: ArcTab = ProcessInfo.processInfo.arguments.contains("-tabPassport") ? .passport
        : ProcessInfo.processInfo.arguments.contains("-tabFriends") ? .friends : .myFlights
    @State private var detent: SheetDetent = ProcessInfo.processInfo.arguments.contains("-sheetLarge") ? .large : .medium
    @State private var showAdd = false
    @State private var detailFlight: Flight?
    @State private var detailDetent: PresentationDetent = .large
    @State private var pendingOpenDetail = ProcessInfo.processInfo.arguments.contains("-openDetail")
    @State private var lastMapMode: Bool?   // true = Passport/hybrid, false = standard
    @State private var planeWatchTask: Task<Void, Never>?

    /// Test hooks for headless screenshots.
    private var addInitialQuery: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-addQuery"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ArcMapView(flights: mapFlights, controller: controller)
                .ignoresSafeArea()

            if let active = activeFlight, active.liveSpeed != nil || active.liveAltitude != nil {
                speedAltPill(active).frame(maxHeight: .infinity, alignment: .top).padding(.top, 6)
            }

            MapControls(controller: controller) { controller.fitAll(mapFlights) }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.trailing, 12).padding(.top, 8)

            // The tab sheet and any presented sheet (detail/add) EXCHANGE —
            // the tab sheet slides away while another sheet is up, so two
            // sheets are never stacked on top of each other.
            BottomSheet(detent: $detent) { sheetContent }
                .offset(y: (detailFlight != nil || showAdd) ? 1500 : 0)
                .animation(.spring(duration: 0.45), value: detailFlight != nil || showAdd)

            ArcTabBar(selection: $tab, onSearch: { showAdd = true })
                .padding(.bottom, 8)
        }
        .sheet(isPresented: $showAdd) {
            AddFlightView(initialQuery: addInitialQuery)
                .presentationDetents([.large])
        }
        .sheet(item: $detailFlight) { flight in
            FlightDetailView(flight: flight, onShowAtGate: { f in showPlaneAtGate(f) })
                .presentationDetents([.medium, .large], selection: $detailDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .onChange(of: allFlights.map(\.id)) { _, _ in
            refitMapForCurrentData()
            openDetailIfPending()
            bootstrapTrackingAndWidgets()
        }
        .onChange(of: tab) { _, newTab in updateCameraForTab(newTab) }
        .onChange(of: detailFlight?.id) { _, _ in
            if let f = detailFlight { controller.focus(on: f) }
        }
        .onChange(of: supabase.isSignedIn) { wasSignedIn, isSignedIn in
            // Backfill flights added before this sign-in — "put flights in
            // Supabase too" should cover what's already here, not just what's
            // added from now on.
            if !wasSignedIn, isSignedIn {
                let flights = allFlights
                Task { await ArcSupabase.shared.bulkUploadFlights(flights) }
            }
        }
        .onAppear {
            DemoSeed.seedIfRequested(into: modelContext, existing: allFlights)
            DemoSeed.seedStuckFlightIfRequested(into: modelContext, existing: allFlights)
            DemoSeed.startDemoLiveActivityIfRequested()
            refitMapForCurrentData()
            openDetailIfPending()
            bootstrapTrackingAndWidgets()
            if ProcessInfo.processInfo.arguments.contains("-openAdd") { showAdd = true }
        }
    }

    private var mapFlights: [Flight] {
        switch tab {
        case .passport: return allFlights.filter { $0.departureLat != 0 && $0.arrivalLat != 0 }
        default: return allFlights.filter { $0.isUpcoming || $0.isActive }
        }
    }

    /// Tab switches only MOVE THE CAMERA — never touch `controller.style`.
    /// A style change swaps MapKit's entire tile layer (a visible full map
    /// reload), and doing that automatically on every Passport switch was
    /// exactly the "map reloads in the background" complaint. Passport's
    /// globe feel comes purely from the zoomed-out camera framing; the
    /// photoreal/hybrid look remains available via the map-style button in
    /// MapControls, where the reload is something the user asked for.
    private func updateCameraForTab(_ t: ArcTab) {
        let wantsPassport = (t == .passport)
        guard lastMapMode != wantsPassport else { return }
        lastMapMode = wantsPassport
        applyCameraForCurrentMode(wantsPassport)
    }

    /// Called when the underlying flight data changes, or on first appear —
    /// always refits (the route set may genuinely differ).
    private func refitMapForCurrentData() {
        let wantsPassport = (tab == .passport)
        lastMapMode = wantsPassport
        applyCameraForCurrentMode(wantsPassport)
    }

    private func applyCameraForCurrentMode(_ passport: Bool) {
        controller.fitAll(mapFlights, padding: passport ? 2.2 : 1.4)
    }

    private func bootstrapTrackingAndWidgets() {
        healBrokenFlightStatuses()
        FlightTracker.shared.startTracking(flights: allFlights, modelContext: modelContext)
        WidgetSync.sync(flights: allFlights)
    }

    /// One-time repair for flights saved before the backend normalized AeroDataBox's
    /// status vocabulary (e.g. "expected"/"arrived") into ours — those got stuck with
    /// a `statusRaw` that matches neither `isUpcoming` nor `isCompleted`, making them
    /// invisible in every list while still rendering their route on the Passport globe.
    private func healBrokenFlightStatuses() {
        var changed = false
        for f in allFlights where FlightStatus(rawValue: f.statusRaw) == nil {
            f.status = FlightStatus.heal(rawValue: f.statusRaw, scheduledArrival: f.scheduledArrival)
            changed = true
        }
        if changed { try? modelContext.save() }
    }

    /// "Plane at gate": zoom the shared map onto the relevant gate (OSM
    /// coordinates) and shrink the detail sheet to medium so the map shows.
    ///
    /// Landed flight → the ARRIVAL gate, static parked-plane marker.
    /// Upcoming flight → the DEPARTURE gate (where the user boards), plus a
    /// LIVE feed of their actual aircraft: the same tail is flying its
    /// inbound rotation, and ADS-B covers arrival, taxi, and parking — so
    /// the user literally watches their plane pull up to the gate. Polling
    /// runs at 8s ONLY while this view is open (user-initiated and bounded,
    /// unlike the global 3-min in-flight throttle).
    private func showPlaneAtGate(_ flight: Flight) {
        let watching = flight.isUpcoming
        let iata = watching ? flight.departureIATA : flight.arrivalIATA
        let lat = watching ? flight.departureLat : flight.arrivalLat
        let lon = watching ? flight.departureLon : flight.arrivalLon
        let gateRef = watching ? flight.departureGate : flight.arrivalGate
        Task {
            var target = (lat: lat, lon: lon, label: iata)
            if let gateRef {
                let gates = await FlightAPIClient.shared.gates(iata: iata, lat: lat, lon: lon)
                if let matched = FlightAPIClient.matchGate(gates, to: gateRef) {
                    target = (matched.lat, matched.lon, "Gate \(gateRef)")
                }
            }
            controller.showGate(lat: target.lat, lon: target.lon, label: target.label)
            detailDetent = .medium
            if watching { startPlaneWatch(flight) }
        }
    }

    private func startPlaneWatch(_ flight: Flight) {
        planeWatchTask?.cancel()
        guard let icao24 = flight.aircraftICAO24 else { return }
        planeWatchTask = Task {
            while !Task.isCancelled {
                // Back button clears the marker — stop burning OpenSky quota.
                guard controller.gateMarker != nil else { break }
                if let pos = try? await FlightAPIClient.shared.livePosition(icao24: icao24) {
                    controller.livePlane = .init(
                        lat: pos.lat, lon: pos.lon,
                        heading: pos.heading, onGround: pos.on_ground)
                }
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    private var activeFlight: Flight? { allFlights.first { $0.isActive } }

    private func speedAltPill(_ f: Flight) -> some View {
        HStack(spacing: 14) {
            if let s = f.liveSpeed {
                Label("\(Int(s * 3.6)) km/h", systemImage: "speedometer")
                    .labelStyle(.titleAndIcon)
            }
            if let a = f.liveAltitude {
                Label(altString(a), systemImage: "arrow.up.to.line")
                    .labelStyle(.titleAndIcon)
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color(.separator).opacity(0.4), lineWidth: 0.5))
    }

    private func altString(_ meters: Double) -> String {
        let f = NumberFormatter(); f.groupingSeparator = "'"; f.numberStyle = .decimal; f.maximumFractionDigits = 0
        return (f.string(from: NSNumber(value: meters)) ?? "\(Int(meters))") + " m"
    }

    private func openDetailIfPending() {
        guard pendingOpenDetail, detailFlight == nil, !allFlights.isEmpty else { return }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-openDetailNumber"), i + 1 < args.count,
           let match = allFlights.first(where: { $0.flightNumber == args[i + 1] }) {
            detailFlight = match
        } else {
            detailFlight = allFlights.first(where: { $0.isActive }) ?? allFlights.first
        }
        pendingOpenDetail = false
    }

    @ViewBuilder private var sheetContent: some View {
        switch tab {
        case .myFlights: MyFlightsView { detailFlight = $0 }
        case .friends: FriendsScreen()
        case .passport: PassportView { detailFlight = $0 }
        }
    }
}


