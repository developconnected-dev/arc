import SwiftUI
import SwiftData

struct ArcRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Flight.scheduledDeparture) private var allFlights: [Flight]
    @ObservedObject private var supabase = ArcSupabase.shared

    @State private var controller = MapController()
    @State private var friendsStore = FriendsStore.shared
    @State private var tab: ArcTab = ProcessInfo.processInfo.arguments.contains("-tabPassport") ? .passport
        : ProcessInfo.processInfo.arguments.contains("-tabFriends") ? .friends : .myFlights
    @State private var detent: SheetDetent = ProcessInfo.processInfo.arguments.contains("-sheetLarge") ? .large : .medium
    @State private var showAdd = false
    @State private var detailFlight: Flight?
    @State private var detailDetent: PresentationDetent = .large
    @State private var pendingOpenDetail = ProcessInfo.processInfo.arguments.contains("-openDetail")
    @State private var lastCameraTab: ArcTab?
    @State private var planeWatchTask: Task<Void, Never>?
    @State private var clipboardQuery: String? = nil
    /// Pasteboard `changeCount` currently being offered, and the last one the
    /// user waved away — tracking the count rather than the content is what
    /// keeps this permission-free.
    @State private var offeredPasteChange: Int?
    @State private var dismissedPasteChange: Int?


    /// Test hooks for headless screenshots.
    private var addInitialQuery: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-addQuery"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ArcMapView(flights: mapFlights, controller: controller,
                       friendOverlays: tab == .friends ? friendsStore.mapOverlays : [])
                .ignoresSafeArea()

            if tab != .friends, let active = activeFlight,
               active.liveSpeed != nil || active.liveAltitude != nil {
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

            if offeredPasteChange != nil, !showAdd, detailFlight == nil, tab == .myFlights {
                clipboardMagicPill
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    // Clears the tab bar (its own height plus its 8pt inset)
                    // rather than lowering the bar, which already sits against
                    // the home indicator.
                    .padding(.bottom, 96)
            }

            ArcTabBar(selection: $tab, onSearch: { showAdd = true })
                .padding(.bottom, 8)
        }
        .sheet(isPresented: $showAdd) {
            AddFlightView(initialQuery: clipboardQuery ?? addInitialQuery)
                .presentationDetents([.large])
                .onDisappear { clipboardQuery = nil }
        }
        .sheet(item: $detailFlight) { flight in
            FlightDetailView(flight: flight,
                             onShowAtGate: { f in showPlaneAtGate(f) },
                             onShowAirport: { f in showAirportView(f) })
                .presentationDetents([.medium, .large], selection: $detailDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .onChange(of: allFlights.map(\.id)) { _, _ in
            refitMapForCurrentData()
            openDetailIfPending()
            bootstrapTrackingAndWidgets()
        }
        .onChange(of: tab) { _, newTab in
            updateCameraForTab(newTab)
            if newTab == .friends {
                Task {
                    await FriendsStore.shared.refresh()
                    // Overlays may have just loaded — frame them.
                    if tab == .friends { applyCameraForCurrentTab() }
                }
            }
        }
        // Cold launch straight into the Friends tab: the store fills AFTER
        // the first camera pass — refit when the friend list materializes.
        .onChange(of: friendsStore.friends.count) { _, _ in
            if tab == .friends { applyCameraForCurrentTab() }
        }
        // Friend-flight detail opened → zoom onto that arc; dismissed →
        // re-frame all friends.
        .onChange(of: friendsStore.focusedRoute) { _, route in
            guard tab == .friends else { return }
            if let route {
                // Make sure the zoom is actually visible: the tab sheet may
                // be at full height under the newly presented detail (which
                // itself opens at the system medium ≈ half screen).
                detent = .small
                controller.focusRoute(dep: route.dep, arr: route.arr)
            } else {
                applyCameraForCurrentTab()
            }
        }
        // arc://friend/<code> — invite links from the /f/ landing page. The
        // code parks in the store: redeemed immediately when a session
        // exists, or right after first-time profile setup when it doesn't.
        // Minute heartbeat while the Friends tab is up: airborne bubbles
        // creep along their arcs between data refreshes (clock math is free —
        // this triggers zero network calls). Cancelled on tab change.
        .task(id: tab) {
            guard tab == .friends else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                FriendsStore.shared.clockTick += 1
            }
        }
        .onOpenURL { url in
            guard url.scheme == "arc", url.host() == "friend" else { return }
            let code = url.lastPathComponent
            guard !code.isEmpty, code != "friend" else { return }
            FriendsStore.shared.pendingInviteCode = code
            tab = .friends
            Task { await FriendsStore.shared.redeemPendingIfPossible() }
        }
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
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { refreshClipboardOffer() }
        }
        // Fetch advisories only once the layer is actually switched on, and only
        // when the cached set is stale.
        .task(id: controller.showWeatherHazards) {
            guard controller.showWeatherHazards else { return }
            await controller.refreshHazardsIfNeeded()
        }
        .onAppear {
            DemoSeed.seedIfRequested(into: modelContext, existing: allFlights)
            DemoSeed.seedStuckFlightIfRequested(into: modelContext, existing: allFlights)
            DemoSeed.startDemoLiveActivityIfRequested()
            refitMapForCurrentData()
            openDetailIfPending()
            bootstrapTrackingAndWidgets()
            refreshClipboardOffer()
            if ProcessInfo.processInfo.arguments.contains("-openAdd") { showAdd = true }
        }
    }

    private var mapFlights: [Flight] {
        switch tab {
        case .passport: return allFlights.filter { $0.departureLat != 0 && $0.arrivalLat != 0 }
        // Friends tab: the globe belongs to friends' flights — the user's
        // own routes would just be noise behind the avatar bubbles.
        case .friends: return []
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
        guard lastCameraTab != t else { return }
        lastCameraTab = t
        applyCameraForCurrentTab()
    }

    /// Called when the underlying flight data changes, or on first appear —
    /// always refits (the route set may genuinely differ).
    private func refitMapForCurrentData() {
        lastCameraTab = tab
        applyCameraForCurrentTab()
    }

    private func applyCameraForCurrentTab() {
        if tab == .friends {
            // Frame the friends' routes (own flights are hidden here) in the
            // upper half — the sheet covers the rest.
            let coords = friendsStore.mapOverlays.flatMap { [$0.dep, $0.arr] }
            if !coords.isEmpty { controller.frameInUpperHalf(coords) }
            return
        }
        controller.fitAll(mapFlights, padding: tab == .passport ? 1.5 : 1.25)
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

    /// "Terminal Map": the in-app airport view. Dives the shared map onto the
    /// contextually relevant airport (departure before the trip, arrival
    /// after) in satellite imagery, renders every OSM gate, highlights the
    /// user's own, and shrinks the detail sheet so the map is the star.
    private func showAirportView(_ flight: Flight) {
        let upcoming = flight.isUpcoming
        let iata = upcoming ? flight.departureIATA : flight.arrivalIATA
        let lat = upcoming ? flight.departureLat : flight.arrivalLat
        let lon = upcoming ? flight.departureLon : flight.arrivalLon
        let myGate = upcoming ? flight.departureGate : flight.arrivalGate
        let name = ReferenceData.shared.airport(iata)?.name ?? iata
        Task {
            let osm = await FlightAPIClient.shared.gates(iata: iata, lat: lat, lon: lon)
            let matched = myGate.flatMap { FlightAPIClient.matchGate(osm, to: $0) }
            let gates = osm.map {
                MapController.AirportGate(
                    ref: $0.ref, lat: $0.lat, lon: $0.lon,
                    highlighted: $0.ref == matched?.ref)
            }
            controller.showAirport(iata: iata, name: name, lat: lat, lon: lon, gates: gates)
            detailDetent = .medium
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

    // MARK: - Liquid Glass Clipboard Pill
    /// Decides whether to OFFER a paste, without reading the clipboard.
    ///
    /// Reading `UIPasteboard.general.string` raises iOS's paste-consent alert —
    /// whose default button is "Don't Allow Paste" — on every single foreground,
    /// and returns nil when declined, so the pill never appeared. `hasStrings`
    /// and `changeCount` are metadata and need no permission; the content is
    /// read inside a `PasteButton`, where the tap itself is the consent and no
    /// alert is shown at all.
    private func refreshClipboardOffer() {
        let pasteboard = UIPasteboard.general
        guard pasteboard.hasStrings else {
            offeredPasteChange = nil
            return
        }
        // One offer per copy: dismissing it shouldn't bring it straight back.
        guard pasteboard.changeCount != dismissedPasteChange else { return }
        withAnimation(.spring(duration: 0.4)) { offeredPasteChange = pasteboard.changeCount }
    }

    /// A bare flight number, if that's all the text is. Anything longer (a whole
    /// booking email) is handed to Add Flight's parser instead of being rejected.
    ///
    /// The designator is two alphanumerics (IATA) or three letters (ICAO), not
    /// `[A-Z]{2,3}` — plenty of airlines have a digit in their code, including
    /// A3 Aegean, 4U, U2 and 6E, and matching letters only silently excluded
    /// every one of them.
    static func flightCode(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The lookahead keeps a bare number like "1413" from reading as a
        // designator plus digits.
        guard trimmed.count < 15,
              trimmed.range(of: "^(?=.*[A-Z])([A-Z]{3}|[A-Z0-9]{2})\\s?\\d{1,4}$",
                            options: [.regularExpression, .caseInsensitive]) != nil
        else { return nil }
        return trimmed.uppercased().replacingOccurrences(of: " ", with: "")
    }

    private func handlePasted(_ raw: String) {
        dismissedPasteChange = UIPasteboard.general.changeCount
        withAnimation(.easeOut) { offeredPasteChange = nil }

        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if let code = Self.flightCode(in: text) {
            let already = allFlights.contains {
                $0.flightNumber.replacingOccurrences(of: " ", with: "").uppercased() == code
            }
            guard !already else { return }
            clipboardQuery = code
        } else {
            // Not a bare number — let the Add screen's parser take the whole thing.
            clipboardQuery = text
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showAdd = true
    }

    /// The paste itself is a `PasteButton`: it hands over the clipboard on tap
    /// with no consent alert, which is the only way this can work without the
    /// system asking (and defaulting to "Don't Allow") every time.
    private var clipboardMagicPill: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(ArcTheme.brand)
            Text("Add a flight you copied")
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(.primary)

            PasteButton(payloadType: String.self) { strings in
                handlePasted(strings.first ?? "")
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.capsule)
            .tint(ArcTheme.brand)

            Button {
                dismissedPasteChange = UIPasteboard.general.changeCount
                withAnimation(.easeOut) { offeredPasteChange = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color(.tertiarySystemFill), in: Circle())
            }.buttonStyle(.plain)
        }
        .padding(.leading, 18).padding(.trailing, 10).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().stroke(
                LinearGradient(colors: [Color.white.opacity(0.6), Color.white.opacity(0.1)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1.2)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 14, x: 0, y: 6)
        .padding(.horizontal, 24)
    }
}


