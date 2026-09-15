import SwiftUI
import MapKit
import SwiftData

struct ArcRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @Query(sort: \Flight.scheduledDeparture) private var allFlights: [Flight]
    @ObservedObject private var supabase = ArcSupabase.shared

    @State private var controller = MapController()
    @State private var friendsStore = FriendsStore.shared
    @State private var tab: ArcTab = ProcessInfo.processInfo.arguments.contains("-tabPassport") ? .passport
        : ProcessInfo.processInfo.arguments.contains("-tabFriends") ? .friends : .myFlights
    @State private var detent: SheetDetent = ProcessInfo.processInfo.arguments.contains("-sheetLarge") ? .large : .medium
    @State private var showAdd = false
    /// My Trips floats over the map (docs/superpowers/specs/2026-09-15-floating-trips-design.md).
    /// `-sheetLarge` still means "show everything": UI tests start unfolded.
    @State private var tripsFolded = !ProcessInfo.processInfo.arguments.contains("-sheetLarge")
    @State private var tripsRestShown = ProcessInfo.processInfo.arguments.contains("-sheetLarge")
    @State private var tripsFoldedHeight: CGFloat = 0
    @State private var tripsLayout: MyTripsLayout?
    /// The detail panel's settled top edge; nil opens at 58 %.
    @State private var panelTop: CGFloat?
    @State private var panelHeaderHeight: CGFloat = 260
    /// How far the tab bar reaches up without the accessory, learnt once.
    @State private var tabBarReach: (width: CGFloat, reach: CGFloat)?
    @State private var detailFlight: Flight?
    @State private var heroFrames = HeroFrames()
    @State private var heroTravelling: HeroSource?
    @State private var heroProgress: Double = 0
    @State private var heroOrigin: CGRect?
    @State private var heroDestination: CGRect?
    @State private var transition = TripTransition()
    @State private var detailTab: ArcTab?
    @State private var mapFocusID: UUID?
    /// Set while the open detail is a friend's flight: the row's feed item.
    @State private var detailFriend: FriendsStore.FeedItem?
    @State private var detailFriendGroup: FriendFlightGroup?
    /// Set while the open detail is a trip invite's preview.
    @State private var detailInvite: FriendsStore.TripInviteItem?
    @State private var pendingOpenDetail = ProcessInfo.processInfo.arguments.contains("-openDetail")
    @State private var lastCameraTab: ArcTab?
    @State private var planeWatchTask: Task<Void, Never>?
    /// The in-flight "Terminal Map"/"My plane" setup (a network fetch, then a
    /// camera dive). Cancelled when its detail closes — otherwise the answer
    /// arrived seconds after dismissal and hijacked the map with a gate view
    /// for a flight that was no longer open.
    @State private var groundViewTask: Task<Void, Never>?
    /// The sheet height before a friend-route zoom shrank it to .small.
    @State private var clipboardQuery: String? = nil
    /// Pasteboard `changeCount` currently being offered, and the last one the
    /// user waved away — tracking the count rather than the content is what
    /// keeps this permission-free.
    @State private var offeredPasteChange: Int?
    @State private var dismissedPasteChange: Int?
    /// A detail screen waiting for the sheet in front of it to go away.
    /// Presenting a second sheet while one is still up is a no-op in SwiftUI,
    /// and swapping a presented sheet's item can drop the replacement on the
    /// floor — so both cases dismiss first and come back through here.
    @State private var queuedDetail: Flight?
    /// The batch that last claimed the add moment, for the list to bring
    /// its topmost row into view (see `MyFlightsView.landed`).
    @State private var landedTrips: [UUID] = []


    /// Test hooks for headless screenshots.
    private var addInitialQuery: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-addQuery"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private var sheetTabs: some View {
        tabs
        // (tab content, map background and accessory live in `tabs` — split out
        // so the modifier chain below stays inside the type checker's budget.)

        .sheet(isPresented: $showAdd) {
            // The moment is claimed at the save — the map is visible behind
            // this sheet as it slides away, and must already be hiding the
            // settled line and framing the route — and the draw starts once
            // the sheet is out of the way.
            AddFlightView(initialQuery: clipboardQuery ?? addInitialQuery,
                          onAdded: { added in holdTrips([added]) })
            .presentationDetents([.large])
            .onDisappear {
                clipboardQuery = nil
                // The map is fully in view now, so this is where the route
                // draws itself on. Unless a widget, notification or `arc://`
                // tap arrived while the sheet was up and queued a specific
                // flight: that detail is about to cover the map and claim the
                // camera for its own flight, so the reveal would play under
                // it, pointed at the wrong trip. The flight the user asked
                // for wins, and the held line goes back to the settled map.
                if queuedDetail != nil { controller.cancelReveal() } else { controller.startReveal() }
                presentQueuedDetail()
            }
        }
        // Belt to the sheets' own onDismiss braces: a queued detail must
        // present whenever nothing is in front of it any more — a cancelled
        // Add presentation (showAdd flipped back before the sheet appeared)
        // never fires onDisappear, and stranded the queued flight forever.
        //
        // The reveal's belt is deliberately LATE: this fires as the sheet
        // STARTS sliding away, and starting the draw here would spend its
        // first third behind the sheet. But a held route is a line the map
        // is hiding, and a hold nobody starts would hide it for the session
        // — so if the sheet's onDisappear hasn't started the draw by the time
        // the dismissal is long over, this does. A no-op whenever it has.
        .onChange(of: showAdd) { _, presented in
            if !presented {
                DispatchQueue.main.async { presentQueuedDetail() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { controller.startReveal() }
            }
        }
        .onChange(of: allFlights.map(\.id)) { _, _ in
            // Saving a trip is what changed this list, so the refit that
            // normally hangs off it would frame every route the user owns and
            // undo the fit the add moment is built around.
            if !controller.isRevealingRoutes { refitMapForCurrentData() }
            openDetailIfPending()
            bootstrapTrackingAndWidgets()
            // A tap that arrived before SwiftData had loaded gets its flight now.
            drainPendingOpen()
            maybeShowNotificationPrimer()
        }
        // A ViewModifier, not an inline .alert: body's chain is already at
        // the type-checker's limit (see `tabs`), and the alert's closures
        // inlined here tipped it into "unable to type-check in reasonable
        // time" — caught by CI, on a build the simulator would have shown
        // the same way.
        .modifier(NotificationPrimerAlert(isPresented: $showNotificationPrimer))
        .onChange(of: tab) { _, newTab in
            if let detailTab, detailTab != newTab {
                // As `closeDetail` does: a Terminal map or My plane left open
                // would otherwise keep diving the map for a detail that's gone.
                groundViewTask?.cancel()
                groundViewTask = nil
                controller.clearGateMarker()
                mapFocusID = nil
                transition.close()
                finishTransition(transition.request!.id)
            }
            updateCameraForTab(newTab)
            if newTab == .friends {
                Task {
                    await FriendsStore.shared.refresh()
                    // Overlays may have just loaded — frame them.
                    if tab == .friends, detailFlight == nil { applyCameraForCurrentTab() }
                }
            }
        }
        // Cold launch straight into the Friends tab: the store fills AFTER
        // the first camera pass — refit when the friend list materializes.
        .onChange(of: friendsStore.friends.count) { _, _ in
            if tab == .friends, detailFlight == nil { applyCameraForCurrentTab() }
        }
        .onChange(of: friendsStore.focusedRoute) { _, route in
            if tab == .friends, route == nil { applyCameraForCurrentTab() }
        }
    }

    var body: some View {
        sheetTabs
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
            guard let dest = ArcDeepLink.parse(url) else { return }
            // A Live Activity / widget tap that LAUNCHES the app delivers its
            // URL while the scene is still inactive — and a sheet presented
            // before the window is active is silently dropped (the camera
            // moved but no detail appeared). Park it; the scenePhase-active
            // drain below presents it the moment presentation can stick.
            if scenePhase == .active {
                open(dest)
            } else {
                PendingFlightOpen.destination = dest
                // The URL can also arrive AFTER the scene-active drain already
                // ran (delivery order isn't guaranteed), which would leave the
                // tap parked until the next foreground. A short delayed drain
                // through the existing notification path covers that ordering;
                // it's a no-op when the phase-change drain got there first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    NotificationCenter.default.post(name: .arcOpenFlight, object: nil)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .arcOpenFlight)) { _ in
            drainPendingOpen()
        }
        .task(id: mapFocusID) { await focusPresentedTrip() }
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
            if newPhase == .active {
                refreshClipboardOffer()
                drainPendingOpen()
            }
        }
        // Fetch advisories only once the layer is actually switched on, and only
        // when the cached set is stale.
        .task(id: controller.showWeatherHazards) {
            guard controller.showWeatherHazards else { return }
            await controller.refreshHazardsIfNeeded()
        }
        .onAppear {
            // A cold launch from a tapped notification can park its destination
            // either side of this view's construction, so drain here as well as
            // on `.arcOpenFlight`: whichever happens second finds it.
            drainPendingOpen()
            DemoSeed.seedIfRequested(into: modelContext, existing: allFlights)
            DemoSeed.seedStuckFlightIfRequested(into: modelContext, existing: allFlights)
            DemoSeed.startDemoLiveActivityIfRequested()
            // One card per flight: sweep up any duplicates left by an older
            // build or a relaunch race, once per app start.
            Task { await LiveActivityManager.shared.reapDuplicateActivities() }
            DemoSeed.seedTripInviteIfRequested()
            DemoSeed.seedGroupedOwnTripIfRequested(into: modelContext)
            DemoSeed.seedFriendsIfRequested()
            refitMapForCurrentData()
            openDetailIfPending()
            bootstrapTrackingAndWidgets()
            refreshClipboardOffer()
            if ProcessInfo.processInfo.arguments.contains("-openAdd") { showAdd = true }
            drainPendingOpen()
        }
    }

    private func focusPresentedTrip() async {
        guard let id = mapFocusID, let flight = detailFlight, flight.id == id else { return }
        // Start on the next turn after the card handoff, never during its travel.
        await Task.yield()
        guard !Task.isCancelled, mapFocusID == id, detailFlight?.id == id else { return }
        if detailTab == .myFlights, let layout = tripsLayout {
            controller.focus(on: flight, band: layout.band(coverTop: panelTop ?? layout.panelOpeningTop(headerHeight: panelHeaderHeight)),
                             animated: !reduceMotion)
        } else {
            controller.focus(on: flight, animated: !reduceMotion)
        }
        if let friend = detailFriend {
            await FriendsStore.shared.refreshLive(friend, updating: flight)
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

    /// The add / import moment.
    ///
    /// Every path that saves a trip ends up here — the Add search, a scanned
    /// boarding pass, a leg off a pasted booking, a train picked off a station
    /// board, manual entry, an accepted trip invite — so what happens next is
    /// identical whichever one it was: the row is in My Trips and the map
    /// draws the route across it in about a second. Nothing is loading by this
    /// point, which is precisely why there is nothing here that says so.
    private func revealTrips(_ flights: [Flight]) {
        holdTrips(flights)
        controller.startReveal()
        // Nothing drawable — a past trip, a hand-typed train with no
        // coordinates — means the row appearing is the whole event. The
        // camera was never claimed, so the list change still gets the refit
        // it would normally trigger.
        if !controller.isRevealingRoutes { refitMapForCurrentData() }
    }

    /// Claim the moment for trips that just landed, without drawing yet:
    /// the tab, the sheet height and the camera are the moment's from the
    /// save on, and the map hides the settled line until `startReveal`.
    /// Every add path today saves one leg and dismisses, so a hold is one
    /// trip; holds before the draw starts join one batch — one camera move,
    /// one shared draw — so a path saving several legs would not race.
    private func holdTrips(_ flights: [Flight]) {
        guard !flights.isEmpty else { return }
        // The row lands in My Trips, so that's the list the map draws behind.
        tab = .myFlights
        // And the list brings that row to the top: the reveal is the route
        // drawing on AND the row appearing, whatever the list was scrolled to.
        landedTrips = flights.map(\.id)
        // The reveal owns the camera for the next second. Claiming the tab
        // here is what stops the tab-change hook from refitting to every
        // route the user has and fighting it.
        lastCameraTab = .myFlights
        // Only what THIS tab's map will actually draw (`mapFlights` shows
        // upcoming and active legs). A hand-logged past trip must not get a
        // reveal: its line would draw itself on and then vanish at the
        // handover, because the settled map was never going to hold it.
        controller.holdRoutes(for: flights.filter { $0.isUpcoming || $0.isActive })
    }

    private func applyCameraForCurrentTab() {
        if tab == .friends {
            // Frame the friends' routes (own flights are hidden here) in the
            // upper half — the sheet covers the rest.
            let coords = friendsStore.mapOverlays.flatMap { [$0.dep, $0.arr] }
            if !coords.isEmpty { controller.frameInUpperHalf(coords) }
            return
        }
        if tab == .myFlights, let layout = tripsLayout {
            // Framed for the folded stack: unfolded, the cards cover the map
            // anyway, and the fold refits once it has settled.
            let coverTop = layout.listTop(folded: true, foldedHeight: tripsFoldedHeight)
            controller.fitAll(mapFlights, padding: 1.25, band: layout.band(coverTop: coverTop))
            return
        }
        controller.fitAll(mapFlights, padding: tab == .passport ? 1.5 : 1.25)
    }

    /// The notification dialog, asked at the one moment it answers itself:
    /// the user just added a flight for Arc to watch. Asked cold at first
    /// launch — the old behaviour — it is the question most likely to be
    /// answered "no". Once per install, only while the user has never
    /// explicitly decided (provisional delivery runs quietly meanwhile),
    /// and never re-nagged after a real answer either way.
    @State private var showNotificationPrimer = false

    private func maybeShowNotificationPrimer() {
        let key = "notificationPrimer.shown"
        guard !DemoSeed.suppressPrompts,
              !allFlights.isEmpty,
              !UserDefaults.standard.bool(forKey: key) else { return }
        Task { @MainActor in
            guard await ArcNotifications.permissionUndecided() else {
                // Already granted or denied elsewhere — nothing to ask, ever.
                UserDefaults.standard.set(true, forKey: key)
                return
            }
            UserDefaults.standard.set(true, forKey: key)
            showNotificationPrimer = true
        }
    }

    fileprivate struct NotificationPrimerAlert: ViewModifier {
        @Binding var isPresented: Bool
        func body(content: Content) -> some View {
            content.alert("Get told when this flight changes?", isPresented: $isPresented) {
                Button("Not now", role: .cancel) {}
                Button("Turn on notifications") { ArcNotifications.requestPermission() }
            } message: {
                Text("Arc watches your flights for gate changes, delays, boarding and cancellations — even while the app is closed.")
            }
        }
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
    /// coordinates) and lower the detail panel (or the sheet on Passport) so
    /// the map shows.
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
        groundViewTask?.cancel()
        groundViewTask = Task {
            var target = (lat: lat, lon: lon, label: iata)
            if let gateRef {
                let gates = await FlightAPIClient.shared.gates(iata: iata, lat: lat, lon: lon)
                if let matched = FlightAPIClient.matchGate(gates, to: gateRef) {
                    target = (matched.lat, matched.lon, "Gate \(gateRef)")
                }
            }
            guard !Task.isCancelled, detailFlight?.id == flight.id else { return }
            controller.showGate(lat: target.lat, lon: target.lon, label: target.label)
            lowerPanelForGroundViewAfterMapUpdate()
            if watching { startPlaneWatch(flight) }
        }
    }

    /// "Terminal Map": the in-app airport view. Dives the shared map onto the
    /// contextually relevant airport (departure before the trip, arrival
    /// after) in satellite imagery, renders every OSM gate, highlights the
    /// user's own, and lowers the detail panel (or the sheet on Passport) so
    /// the map is the star.
    private func showAirportView(_ flight: Flight) {
        let upcoming = flight.isUpcoming
        let iata = upcoming ? flight.departureIATA : flight.arrivalIATA
        let lat = upcoming ? flight.departureLat : flight.arrivalLat
        let lon = upcoming ? flight.departureLon : flight.arrivalLon
        let myGate = upcoming ? flight.departureGate : flight.arrivalGate
        let name = ReferenceData.shared.airport(iata)?.name ?? iata
        groundViewTask?.cancel()
        groundViewTask = Task {
            let osm = await FlightAPIClient.shared.gates(iata: iata, lat: lat, lon: lon)
            guard !Task.isCancelled, detailFlight?.id == flight.id else { return }
            let matched = myGate.flatMap { FlightAPIClient.matchGate(osm, to: $0) }
            let gates = osm.map {
                MapController.AirportGate(
                    ref: $0.ref, lat: $0.lat, lon: $0.lon,
                    highlighted: $0.ref == matched?.ref)
            }
            controller.showAirport(iata: iata, name: name, lat: lat, lon: lon, gates: gates)
            lowerPanelForGroundViewAfterMapUpdate()
            // The terminal map used to draw the gates and then sit there. The
            // aircraft is the reason you opened it.
            startPlaneWatch(flight)
        }
    }

    /// Terminal map / My plane need the map: a panel dragged taller than
    /// its opening height comes back down, in the spring the camera dives with.
    /// A detail in Passport's sheet drops the sheet to medium, as it always has.
    private func lowerPanelForGroundView() {
        guard detailTab == .myFlights, let layout = tripsLayout else {
            withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.88)) { detent = .medium }
            return
        }
        let lowered = layout.panelTopForGroundView(current: panelTop ?? layout.panelOpeningTop(headerHeight: panelHeaderHeight),
                                                   headerHeight: panelHeaderHeight)
        withAnimation(reduceMotion ? nil : ArcTheme.panelSettle) { panelTop = lowered }
    }

    /// The ground views switch the map to satellite, and MapKit's style swap
    /// holds the main thread for a few frames. A spring started in that same
    /// update lost its first frames to the stall and the panel jumped ~80 pt;
    /// started on the next turn, it moves from its first frame, a beat after
    /// the camera sets off.
    private func lowerPanelForGroundViewAfterMapUpdate() {
        let id = detailFlight?.id
        DispatchQueue.main.async {
            guard detailFlight?.id == id else { return }
            lowerPanelForGroundView()
        }
    }

    /// Follows the aircraft while either ground view is open.
    ///
    /// Two bugs lived here. The loop stopped as soon as `gateMarker` was nil,
    /// but opening the terminal map CLEARS that marker — so switching to it
    /// killed the very feed it needed. And a missing hex code aborted outright,
    /// which is common on a flight added before its aircraft was assigned;
    /// the registration identifies it just as well.
    private func startPlaneWatch(_ flight: Flight) {
        planeWatchTask?.cancel()
        let icao24 = flight.aircraftICAO24
        let registration = flight.aircraftRegistration
        guard icao24 != nil || registration != nil else { return }

        planeWatchTask = Task {
            var framedRemote = false
            while !Task.isCancelled {
                // Either ground view being open is reason to keep looking; both
                // being closed means the user left, so stop the polling.
                guard controller.gateMarker != nil || controller.airportView != nil else { break }
                if let pos = try? await FlightAPIClient.shared.livePosition(
                    icao24: icao24, registration: registration) {
                    controller.livePlane = .init(
                        lat: pos.lat, lon: pos.lon,
                        heading: pos.heading, onGround: pos.on_ground)
                    controller.livePlaneFlightID = flight.id
                    controller.livePlaneAircraftKeys = Set(
                        [icao24, registration].compactMap { $0?.lowercased() })

                    // Is the aircraft actually here? For a flight hours out,
                    // "My plane" usually isn't at this airport yet — it's mid-
                    // rotation somewhere else, and an empty gate answers
                    // nothing. Fly the camera to where the plane really is.
                    let gate = controller.gateMarker.map {
                        CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                    }
                    let farFromGate = gate.map {
                        CLLocation(latitude: pos.lat, longitude: pos.lon)
                            .distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) > 5_000
                    } ?? false

                    if pos.on_ground && !farFromGate {
                        // Keep the aircraft and its gate framed together so it
                        // can't taxi out of view.
                        controller.followTaxi(
                            plane: .init(latitude: pos.lat, longitude: pos.lon),
                            gate: gate)
                    } else if !framedRemote && (farFromGate || !pos.on_ground) {
                        // Once, not every fix: an airborne plane would drag the
                        // camera every 8 seconds and make the map unusable.
                        framedRemote = true
                        controller.frameRemotePlane(
                            plane: .init(latitude: pos.lat, longitude: pos.lon),
                            airborne: !pos.on_ground)
                    }
                }
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    /// A tap that arrived while SwiftData was still loading is retried rather
    /// than dropped; anything the store genuinely doesn't have is discarded, so
    /// a deleted flight can't hijack a later launch.
    private func drainPendingOpen() {
        guard let dest = PendingFlightOpen.destination else { return }
        if open(dest) { PendingFlightOpen.destination = nil }
    }

    /// Routes one destination, whether it came from an `arc://` URL or a tapped
    /// notification. Returns false only when a flight was asked for and the
    /// store hasn't loaded yet — the caller keeps it pending.
    @discardableResult
    private func open(_ dest: ArcDeepLink.Destination) -> Bool {
        switch dest {
        case .directions(let iata, let terminal):
            guard let airport = ReferenceData.shared.airport(iata) else {
                // Not in the bundled table: hand Maps the query instead of
                // consuming the tap into nothing.
                if let url = URL(string: "maps://?q=\(iata)%20airport") { openURL(url) }
                return true
            }
            let item = MKMapItem(
                location: CLLocation(latitude: airport.lat, longitude: airport.lon),
                address: nil)
            item.name = terminal.map { "\(airport.name) · Terminal \($0)" } ?? airport.name
            item.openInMaps(launchOptions:
                [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
            return true
        case .friend(let code):
            FriendsStore.shared.pendingInviteCode = code
            tab = .friends
            Task { await FriendsStore.shared.redeemPendingIfPossible() }
            return true
        case .friendFlight(let id):
            // Parked rather than presented: on a cold launch the feed has not
            // been read yet, so there is nothing to open for another second or
            // two. FriendsView drains it once the flight exists.
            FriendsStore.shared.pendingFlightId = id
            tab = .friends
            return true
        case .flight(let id):
            return show(allFlights.first { $0.id == id })
        case .flightIdentity(let number, let dep, let arr):
            let norm = Self.normalizedNumber(number)
            let sameNumber = allFlights.filter { Self.normalizedNumber($0.flightNumber) == norm }
            let onRoute = sameNumber.filter {
                $0.departureIATA.caseInsensitiveCompare(dep) == .orderedSame
                    && $0.arrivalIATA.caseInsensitiveCompare(arr) == .orderedSame
            }
            return show(mostRelevant(onRoute) ?? mostRelevant(sameNumber))
        }
    }

    /// Which instance a tap meant: a number like "LX14" names a flight that
    /// flies every day, so prefer the one in the air, then the next to leave,
    /// and only then the most recent one flown.
    private func mostRelevant(_ flights: [Flight]) -> Flight? {
        if let active = flights.first(where: { $0.isActive }) { return active }
        if let next = flights.filter({ $0.isUpcoming })
            .min(by: { $0.effectiveDeparture < $1.effectiveDeparture }) { return next }
        return flights.max(by: { $0.scheduledDeparture < $1.scheduledDeparture })
    }

    private static func normalizedNumber(_ raw: String) -> String {
        raw.replacingOccurrences(of: " ", with: "").uppercased()
    }

    /// Presents a flight's detail. Never opens a second sheet on top of Add —
    /// that silently does nothing in SwiftUI — it queues behind its dismissal
    /// instead.
    ///
    /// Adding a trip does NOT come through here. A save used to open the new
    /// trip's detail, which meant the confirmation was a sheet covering both
    /// the list the row had just joined and the map the route had just been
    /// drawn on. The add lands on the list now; this is for a widget, a
    /// notification or an `arc://` link, where a specific flight was asked for.
    private func show(_ flight: Flight?) -> Bool {
        tab = .myFlights
        guard let flight else {
            // Nothing matched: real miss once flights exist, otherwise the
            // store simply hasn't loaded and the caller should retry.
            return !allFlights.isEmpty
        }
        if showAdd {
            queuedDetail = flight
            showAdd = false
        } else {
            openDetail(flight)
        }
        return true
    }

    /// The row becomes the detail. The detail is inserted hidden; on the
    /// next frame, once its card has reported where it is, the overlay's
    /// copy of the row glides up to it while the list fades and the detail
    /// comes in. When it lands, the detail's own card takes over.
    private func openDetail(_ flight: Flight) {
        open(.own(flight))
    }

    /// A friend's flight from the feed: a transient Flight built from the
    /// shared row, refreshed live once open, with their route focused on
    /// the map for as long as the detail is up.
    private func openFriendFlight(_ group: FriendFlightGroup) {
        let item = group.representative
        detailFriendGroup = group
        let store = FriendsStore.shared
        let flight = store.transientFlight(for: item)
        detailFriend = item
        if let dlat = item.flight.departure_lat, let dlon = item.flight.departure_lon,
           let alat = item.flight.arrival_lat, let alon = item.flight.arrival_lon {
            store.focusedRoute = .init(
                id: item.flight.id,
                dep: .init(latitude: dlat, longitude: dlon),
                arr: .init(latitude: alat, longitude: alon),
                mode: item.flight.tripMode)
        }
        open(.friend(group, flight))
    }

    /// An invited trip's preview, from its card in My Trips: read-only, the
    /// inviter named beneath the header.
    private func openInvitePreview(_ item: FriendsStore.TripInviteItem, _ flight: Flight) {
        detailInvite = item
        open(.invite(item, flight))
    }

    private func open(_ source: HeroSource) {
        let flight = source.flight
        let closing = transition.phase == .closing && detailTab == tab && detailFlight != nil
        // Another of the user's trips asked for while one is closing (a
        // widget, notification or link tap): let the close land, then open
        // it. Swapped in mid-close, the new trip's content showed in a
        // half-faded panel over the list while the old card flew home.
        // (Friends' and invites' rows can't be tapped while a detail closes.)
        if closing, detailFlight?.id != flight.id, case .own = source {
            queuedDetail = flight
            return
        }
        switch source {
        case .own: detailFriend = nil; detailFriendGroup = nil; detailInvite = nil
        case .friend: detailInvite = nil
        case .invite: detailFriend = nil; detailFriendGroup = nil
        }
        // The same trip asked for again while it closes isn't one being
        // replaced: the new request reverses the glide from where it is.
        // Settling it instead snapped the whole panel in for one frame.
        let reversing = closing && detailFlight?.id == flight.id
        let replacing = detailFlight != nil && !reversing
        mapFocusID = nil
        detailTab = tab
        detailFlight = flight
        // Reopening the trip that is closing keeps the height it is fading at.
        if !reversing { panelTop = nil }
        if reduceMotion || replacing {
            transition.settle(detail: true)
            heroTravelling = nil
            heroProgress = 1
            mapFocusID = flight.id
            return
        }
        if reversing {
            // The latest ask wins over one queued earlier in this close.
            queuedDetail = nil
            // Mid-flight between the same two frames (or the same fade, when
            // the row was out of view): turn it round from where it is.
            transition.open()
            return
        }
        heroProgress = 0
        heroOrigin = heroRowOrigin(source.key, onTrips: tab == .myFlights)
        heroDestination = nil
        heroTravelling = heroOrigin == nil ? nil : source
        transition.open()
    }

    /// Where the row to glide from is — but only if it's on screen. The
    /// frames outlive the rows: a card folded away still has one, and a glide
    /// from it would start out of nowhere, below the stack.
    private func heroRowOrigin(_ key: String, onTrips: Bool) -> CGRect? {
        guard let rect = heroFrames.rows[key] else { return nil }
        guard onTrips, let layout = tripsLayout else { return rect }
        let shown = (layout.listTop(folded: tripsFolded, foldedHeight: tripsFoldedHeight) - 1)...(layout.listBottom + 1)
        return shown.contains(rect.minY) && shown.contains(rect.maxY) ? rect : nil
    }

    /// Records the header's height and returns how far that moved the
    /// panel's opening top — non-zero only where the header rule binds
    /// (a short screen, large type) and the panel hasn't been dragged.
    @discardableResult
    private func learnPanelHeader(_ measured: CGRect) -> CGFloat {
        guard panelTop == nil, let layout = tripsLayout else {
            panelHeaderHeight = measured.height
            return 0
        }
        let before = layout.panelOpeningTop(headerHeight: panelHeaderHeight)
        panelHeaderHeight = measured.height
        return layout.panelOpeningTop(headerHeight: measured.height) - before
    }

    private func prepareTransition(_ id: UUID) {
        guard transition.request?.id == id else { return }
        guard let source = heroTravelling else {
            // No glide (the row was half out of view), but the panel still
            // fades in: learn the header now, or it re-clamps once it shows.
            let key = detailFriendGroup?.id ?? detailInvite?.id ?? detailFlight?.id.uuidString
            if detailTab == .myFlights, let key, let header = heroFrames.details[key] {
                learnPanelHeader(header)
            }
            return
        }
        // A request that turns a running glide round (a reopen mid-close, a
        // close mid-open) keeps the aim the glide already has; only a fresh
        // opening clears it. Re-aimed here, the header is measured on a panel
        // part-way through its rise while the stored progress already holds
        // the old target, so `settledFrame` corrected by the wrong amount: a
        // reopened card aimed up to 28 pt high and snapped onto the header.
        guard heroDestination == nil else { return }
        guard detailTab == .myFlights, let measured = heroFrames.details[source.key] else {
            heroDestination = heroFrames.details[source.key]
            return
        }
        // The opening height depends on the header, so learn it BEFORE the
        // glide aims — learnt at the landing, the panel would re-clamp and
        // jump just as the card arrives. The header was measured on a panel
        // still risen by the rest of its rise, at the old opening top; aim
        // for where it will settle, at the new one.
        let shift = learnPanelHeader(measured)
        heroDestination = Morph.settledFrame(measured, progress: heroProgress).offsetBy(dx: 0, dy: shift)
    }

    private func finishTransition(_ id: UUID) {
        guard transition.finish(id) else { return }
        heroTravelling = nil
        heroOrigin = nil
        heroDestination = nil
        if transition.phase == .list {
            heroProgress = 0
            if detailFriend != nil { FriendsStore.shared.focusedRoute = nil }
            detailFlight = nil
            detailTab = nil
            presentQueuedDetail()
        } else {
            let key = detailFriendGroup?.id ?? detailInvite?.id ?? detailFlight?.id.uuidString
            if let key, let header = heroFrames.details[key] { panelHeaderHeight = header.height }
            heroProgress = 1
            mapFocusID = detailFlight?.id
        }
    }

    private func closeDetail() {
        guard let flight = detailFlight else { return }
        groundViewTask?.cancel()
        groundViewTask = nil
        controller.clearGateMarker()
        mapFocusID = nil
        let source: HeroSource = detailFriendGroup.map { .friend($0, flight) }
            ?? detailInvite.map { .invite($0, flight) }
            ?? .own(flight)
        if reduceMotion {
            transition.close()
            finishTransition(transition.request!.id)
            return
        }
        if heroTravelling == nil {
            heroOrigin = heroRowOrigin(source.key, onTrips: detailTab == .myFlights)
            heroDestination = heroFrames.details[source.key]
            heroTravelling = heroOrigin == nil ? nil : source
        }
        // A new request reverses a running animation in the SAME host. No
        // overlay appearance event or fresh geometry report is required.
        transition.close()
    }

    private func presentQueuedDetail() {
        guard let queued = queuedDetail else { return }
        // Something is still presented — wait for ITS dismissal to drain.
        guard detailFlight == nil, !showAdd else { return }
        queuedDetail = nil
        openDetail(queued)
    }

    private func openDetailIfPending() {
        guard pendingOpenDetail, detailFlight == nil, !allFlights.isEmpty else { return }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-openDetailNumber"), i + 1 < args.count,
           let match = allFlights.first(where: { $0.flightNumber == args[i + 1] }) {
            openDetail(match)
        } else {
            openDetail(allFlights.first(where: { $0.isActive }) ?? allFlights.first!)
        }
        pendingOpenDetail = false
    }

    /// Native TabView: the system draws the Liquid Glass bar and owns the
    /// safe-area insets. The map is the TabView's BACKGROUND rather than content
    /// inside each tab — a background is built once, so there is still exactly
    /// one MKMapView behind all three tabs and the camera never resets on
    /// switch. Split out of `body` because the modifier chain there is long
    /// enough to defeat the type checker on its own.
    private var tabs: some View {
        TabView(selection: $tab) {
                Tab(ArcTab.myFlights.title, systemImage: ArcTab.myFlights.icon, value: ArcTab.myFlights) {
                    myTripsSurface
                }
                // Trips friends added for the two of you, waiting on an answer.
                .badge(friendsStore.tripInvites.count)
                Tab(ArcTab.friends.title, systemImage: ArcTab.friends.icon, value: ArcTab.friends) {
                    tabSurface(.friends) { FriendsScreen(onSelect: { item in openFriendFlight(item) }) }
                }
                Tab(ArcTab.passport.title, systemImage: ArcTab.passport.icon, value: ArcTab.passport) {
                    tabSurface(.passport) { PassportView { openDetail($0) } }
                }
            }

        // The old circular search button competed with the tab bar for the same
        // corner. The accessory is the native slot for a persistent primary
        // action, and it doubles as the home for the paste offer.
        .modifier(JourneyAccessory(isEnabled: tripsAccessoryEnabled, accessory: bottomAccessory))
    }

    /// Everything that belongs to the map, built once behind the tabs.
    private var mapLayer: some View {
        ZStack(alignment: .top) {
            ArcMapView(flights: mapFlights, controller: controller,
                       friendOverlays: tab == .friends ? friendsStore.mapOverlays : [])
                .ignoresSafeArea()

            // My Trips carries map style and weather in its top row's menu and
            // recenter above its cards (MapTopBar); the sheet tabs keep the column.
            if tab != .myFlights {
                MapControls(controller: controller) { controller.fitAll(mapFlights) }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 12).padding(.top, 8)
            }
        }
    }

    /// The travelling copy of the tapped row, placed between where the list
    /// row is and where the detail's card is. Nothing while nothing travels.
    @ViewBuilder
    private func heroOverlay(glass: Bool, fallback: @escaping (CGSize, CGFloat) -> CGRect) -> some View {
        if let source = heroTravelling, let from = heroOrigin {
            GeometryReader { geo in
                let origin = geo.frame(in: .global).origin
                let local = { (r: CGRect) in r.offsetBy(dx: -origin.x, dy: -origin.y) }
                HeroCard(source: source, progress: heroProgress, glass: glass)
                    .modifier(HeroPlacement(progress: heroProgress,
                                            from: local(from),
                                            to: heroDestination.map(local) ?? fallback(geo.size, from.height)))
            }
            .allowsHitTesting(false)
        }
    }

    /// Friends and Passport show the same draggable sheet over the shared map —
    /// the detent is shared state, so the height carries across them exactly as
    /// before. The sheet still slides away while a detail or add sheet is up, so
    /// two sheets are never stacked. My Trips floats instead (`myTripsSurface`).
    private func tabSurface<Content: View>(_ surfaceTab: ArcTab, @ViewBuilder _ content: () -> Content) -> some View {
        // Built here rather than passed along, so the closure needn't escape.
        let built = content()
        let active = detailTab == surfaceTab && tab == surfaceTab
        return ZStack {
            // iOS gives no way to clear a TabView's container background
            // (`.containerBackground(for: .tabView)` is unavailable here), so the
            // map has to live inside the tab rather than behind it. The camera
            // and every layer are driven by the shared MapController, so
            // switching tabs keeps the same view of the world.
            mapLayer
            // The accessory sits above the tab bar and adds height the custom
            // sheet knows nothing about, so its content needs the clearance —
            // otherwise the last control on a screen hides behind it.
            BottomSheet(detent: $detent) {
                // The detail lives IN the sheet, over the tab content, which
                // stays in the tree (so its rows keep reporting where they
                // are, and the list keeps its scroll position) and merely
                // fades. The tapped row's card travels between the two in
                // the overlay below (see `Morph`).
                ZStack {
                    built
                        .modifier(SidePresence(side: .list, progress: active ? heroProgress : 0))
                        .accessibilityHidden(active && detailFlight != nil)
                        .allowsHitTesting(!active || detailFlight == nil)
                    if active, let flight = detailFlight {
                        let own = detailFriend == nil && detailInvite == nil
                        FlightDetailView(flight: flight,
                                         isOwnFlight: own,
                                         onShowAtGate: own ? { f in showPlaneAtGate(f) } : nil,
                                         onShowAirport: own ? { f in showAirportView(f) } : nil,
                                         onOpenFlight: own ? { other in _ = show(other) } : nil,
                                         onClose: { closeDetail() },
                                         friend: detailFriend?.user ?? detailInvite?.sender,
                                         heroKey: detailFriendGroup?.id ?? detailInvite?.id,
                                         travelGroup: detailFriendGroup,
                                         transitionActive: transition.request != nil,
                                         friendNote: detailInvite != nil ? "Invited you" : "Shared with you")
                            .id(flight.id)
                            .background {
                                Color.clear.frame(width: 1, height: 1)
                                    .accessibilityElement()
                                    .accessibilityIdentifier(transition.request == nil ? "trip-detail-ready" : "trip-detail-transition")
                            }
                            .modifier(SidePresence(side: .detail, progress: heroProgress))
                    }
                }
                .overlay {
                    if active {
                        heroOverlay(glass: false) { size, rowHeight in Morph.target(in: size, rowHeight: rowHeight) }
                    }
                }
                .padding(.bottom, 56)
                .modifier(TripTransitionDriver(request: active ? transition.request : nil,
                                               progress: $heroProgress,
                                               prepare: prepareTransition,
                                               finish: finishTransition))
                .environment(\.heroFrames, heroFrames)
                .environment(\.heroTravelling, active ? heroTravelling?.key : nil)
            }
            .offset(y: showAdd ? 1500 : 0)
            .animation(.spring(duration: 0.45), value: showAdd)
        }
    }

    // MARK: - My Trips, floating

    private var tripsAccessoryEnabled: Bool {
        guard tab == .myFlights else { return true }
        return !allFlights.isEmpty && !(detailTab == .myFlights && detailFlight != nil)
    }

    /// iOS 26.1 can switch the accessory slot off; 26.0 keeps it on screen.
    private static var accessoryCanHide: Bool {
        if #available(iOS 26.1, *) { return true } else { return false }
    }

    /// My Trips: no sheet. The map fills the screen, the trips float over it
    /// as glass cards, and a trip opens in a glass panel the row glides into.
    private var myTripsSurface: some View {
        // Once per root pass: grouping runs the connection planner.
        let journeyCount = MyFlightsView.journeys(Array(allFlights)).count
        return GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let full = CGSize(width: geo.size.width + insets.leading + insets.trailing,
                              height: geo.size.height + insets.top + insets.bottom)
            let learnt = tabBarReach.flatMap { $0.width == full.width ? $0.reach : nil }
            let layout = MyTripsLayout(size: full, safeTop: insets.top,
                                       tabBarClearance: learnt ?? guessTabBarReach(bottomInset: insets.bottom),
                                       accessoryHidesForDetail: Self.accessoryCanHide,
                                       listClearsAccessory: !allFlights.isEmpty || !Self.accessoryCanHide)
            myTripsLayers(layout, journeyCount: journeyCount)
                .frame(width: full.width, height: full.height, alignment: .topLeading)
                .offset(x: -insets.leading, y: -insets.top)
                .onChange(of: layout, initial: true) { _, new in tripsLayout = new }
                .onChange(of: panelHeaderHeight) { _, header in
                    if let top = panelTop { panelTop = layout.clampPanelTop(top, headerHeight: header) }
                }
                .onChange(of: insets.bottom, initial: true) { _, bottom in
                    learnTabBarReach(bottomInset: bottom, width: full.width)
                }
                .onChange(of: full.width) { _, width in
                    learnTabBarReach(bottomInset: insets.bottom, width: width)
                }
        }
        .modifier(MyTripsSurfaceHooks(journeyCount: journeyCount,
                                      detailID: detailFlight?.id,
                                      firstFrameReady: tripsLayout != nil && tripsFoldedHeight > 0,
                                      onJourneyCount: { count in
                                          // Only the pill folds, and it is gone with one journey left.
                                          if count <= 1, !tripsFolded { setTripsFolded(true) }
                                      },
                                      onDetailSettled: learnHeaderWithoutGlide,
                                      onFirstFrame: refitTripsForFirstFrame))
    }

    /// The tab bar's reach without the accessory, from an inset that
    /// includes the accessory while it shows (bottom inset 139 with it, 83
    /// without, on the simulator).
    private func guessTabBarReach(bottomInset: CGFloat) -> CGFloat {
        let accessoryOnScreen = !Self.accessoryCanHide || tripsAccessoryEnabled
        return bottomInset - (accessoryOnScreen ? MyTripsLayout.accessoryHeight : 0)
    }

    /// Learnt per screen width, never re-guessed from the flag while that
    /// width holds: the inset follows the accessory a frame or more after the
    /// flag, and re-guessing moved the cards 56 pt on close and the panel's
    /// height mid-glide. Only two insets can ever be observed, the reach and
    /// the reach plus the accessory, so an inset 56 below the learnt reach, or
    /// 112 above it, proves a first guess made while the two disagreed wrong.
    private func learnTabBarReach(bottomInset bottom: CGFloat, width: CGFloat) {
        guard bottom > 0 else { return }
        guard let learnt = tabBarReach, learnt.width == width else {
            tabBarReach = (width, guessTabBarReach(bottomInset: bottom))
            return
        }
        guard Self.accessoryCanHide else { return }
        if abs((learnt.reach - bottom) - MyTripsLayout.accessoryHeight) < 1 {
            tabBarReach = (width, bottom)
        } else if abs((bottom - learnt.reach) - 2 * MyTripsLayout.accessoryHeight) < 1 {
            tabBarReach = (width, bottom - MyTripsLayout.accessoryHeight)
        }
    }

    /// An opening with no glide (Reduce Motion, one detail replacing another)
    /// never runs `prepareTransition`: learn the new header once it has laid out.
    private func learnHeaderWithoutGlide() async {
        try? await Task.sleep(for: .milliseconds(16))
        guard !Task.isCancelled, transition.request == nil, detailTab == .myFlights,
              let flight = detailFlight else { return }
        let key = detailFriendGroup?.id ?? detailInvite?.id ?? flight.id.uuidString
        if let header = heroFrames.details[key] { learnPanelHeader(header) }
    }

    /// The launch fit runs before the surface has measured itself; frame
    /// again, once, for the real layout and the real folded stack.
    private func refitTripsForFirstFrame() {
        guard tab == .myFlights, detailFlight == nil, !controller.isRevealingRoutes else { return }
        applyCameraForCurrentTab()
    }

    @ViewBuilder
    private func myTripsLayers(_ layout: MyTripsLayout, journeyCount: Int) -> some View {
        let onTrips = detailTab == .myFlights && tab == .myFlights
        let listTop = layout.listTop(folded: tripsFolded, foldedHeight: tripsFoldedHeight)
        ZStack(alignment: .topLeading) {
            mapLayer
            tripsList(layout, listTop: listTop, detailOpen: onTrips && detailFlight != nil)
            // Gone while a detail is settled open: hidden and faded, its
            // buttons were still VoiceOver stops. Rebuilt as a close begins,
            // at the list's ~0 presence, so it still fades back in.
            if !(onTrips && detailFlight != nil && transition.phase == .detail) {
                tripsPillRow(layout, listTop: listTop, journeyCount: journeyCount,
                             detailOpen: onTrips && detailFlight != nil)
            }
            if onTrips, let flight = detailFlight {
                tripsPanel(layout, flight: flight)
            }
            if onTrips {
                heroOverlay(glass: true) { size, rowHeight in
                    Morph.panelTarget(panelTop: panelTop ?? layout.panelOpeningTop(headerHeight: panelHeaderHeight),
                                      width: size.width, rowHeight: rowHeight)
                }
            }
            MapTopBar(layout: layout, controller: controller,
                      liveFlight: tripsLiveFlight, shareFlight: tripsShareFlight)
        }
        .environment(\.heroFrames, heroFrames)
        .environment(\.heroTravelling, onTrips ? heroTravelling?.key : nil)
        .modifier(TripTransitionDriver(request: onTrips ? transition.request : nil,
                                       progress: $heroProgress,
                                       prepare: prepareTransition,
                                       finish: finishTransition))
    }

    /// Placed by offset and revealed by a mask, never resized: a fold
    /// animates two render properties, not the scroll view's layout.
    private func tripsList(_ layout: MyTripsLayout, listTop: CGFloat, detailOpen: Bool) -> some View {
        MyFlightsView(onSelect: { openDetail($0) },
                      onAdd: { showAdd = true },
                      onImported: { imported in revealTrips([imported]) },
                      onPreview: { item, flight in openInvitePreview(item, flight) },
                      landed: landedTrips,
                      folded: tripsFolded,
                      showsRest: tripsRestShown,
                      revealing: controller.isRevealingRoutes,
                      onFoldedHeight: { tripsFoldedHeight = $0 },
                      onUnfold: { then in setTripsFolded(false, then: then) })
            .frame(width: layout.size.width, height: layout.listBottom - layout.unfoldedListTop, alignment: .top)
            // 6 pt of slack so the folded card's glass rim is never clipped;
            // less than the 10 pt gap, so the next card never peeks.
            .mask(alignment: .top) {
                Rectangle().frame(height: max(0, layout.listBottom - listTop + 6))
            }
            // Masked cards still hit-test: only what shows may take a touch,
            // so the accessory and tab bar below a folded stack stay tappable.
            .contentShape(.interaction, TopSlice(height: layout.listBottom - listTop + 6))
            .offset(y: listTop)
            .modifier(SidePresence(side: .list, progress: detailTab == .myFlights && tab == .myFlights ? heroProgress : 0))
            .modifier(UntilMeasured(measured: tripsFoldedHeight > 0))
            .allowsHitTesting(!detailOpen)
            .accessibilityHidden(detailOpen)
            .offset(y: showAdd ? 1500 : 0)
            .animation(reduceMotion ? nil : .spring(duration: 0.45), value: showAdd)
    }

    private func tripsPillRow(_ layout: MyTripsLayout, listTop: CGFloat, journeyCount: Int, detailOpen: Bool) -> some View {
        HStack {
            if journeyCount > 1 {
                Button {
                    // A turn later, not inside the tap: the button's press
                    // release animates its label in the tap's own update, so a
                    // fold started there slid the pill on that animation, over
                    // the first card and past the stack's edge, even with
                    // Reduce Motion on. Out of it, the pill rides the fold.
                    let target = !tripsFolded
                    DispatchQueue.main.async { setTripsFolded(target) }
                } label: {
                    Text(tripsFolded ? "Show More" : "Show Less")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .contentTransition(.interpolate)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("trips-fold-toggle")
            }
            Spacer()
            if !mapFlights.isEmpty {
                RecenterButton { applyCameraForCurrentTab() }
            }
        }
        .padding(.horizontal, MyTripsLayout.margin)
        .frame(width: layout.size.width, height: MyTripsLayout.control)
        .offset(y: layout.pillRowY(listTop: listTop))
        .modifier(SidePresence(side: .list, progress: detailTab == .myFlights && tab == .myFlights ? heroProgress : 0))
        .modifier(UntilMeasured(measured: tripsFoldedHeight > 0))
        .allowsHitTesting(!detailOpen)
        .accessibilityHidden(detailOpen)
        .offset(y: showAdd ? 1500 : 0)
        .animation(reduceMotion ? nil : .spring(duration: 0.45), value: showAdd)
    }

    private func tripsPanel(_ layout: MyTripsLayout, flight: Flight) -> some View {
        let own = detailFriend == nil && detailInvite == nil
        let settled = Binding<CGFloat>(get: { panelTop ?? layout.panelOpeningTop(headerHeight: panelHeaderHeight) },
                                       set: { panelTop = $0 })
        return FloatingPanel(layout: layout, headerHeight: panelHeaderHeight, top: settled,
                             onRecenter: { recenterOnDetail() }) {
            FlightDetailView(flight: flight,
                             isOwnFlight: own,
                             onShowAtGate: own ? { f in showPlaneAtGate(f) } : nil,
                             onShowAirport: own ? { f in showAirportView(f) } : nil,
                             onOpenFlight: own ? { other in _ = show(other) } : nil,
                             onClose: { closeDetail() },
                             friend: detailFriend?.user ?? detailInvite?.sender,
                             heroKey: detailFriendGroup?.id ?? detailInvite?.id,
                             travelGroup: detailFriendGroup,
                             transitionActive: transition.request != nil,
                             friendNote: detailInvite != nil ? "Invited you" : "Shared with you")
                .id(flight.id)
                // Its own tiny element: set on the detail, the identifier spread
                // to the X in its offset overlay and UI tests tapped the detail's centre.
                .background {
                    Color.clear.frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityIdentifier(transition.request == nil ? "trip-detail-ready" : "trip-detail-transition")
                }
        }
        .frame(width: layout.size.width, height: layout.panelBottom - layout.panelHighestTop, alignment: .top)
        .offset(y: layout.panelHighestTop)
        .modifier(PanelPresence(progress: heroProgress))
        .offset(y: showAdd ? 1500 : 0)
    }

    /// Folding and unfolding ride one spring. Cards past the next journey
    /// exist from the moment an unfold starts until a fold has closed over
    /// them, and the camera reframes only once a fold has settled — never
    /// two movements at once.
    private func setTripsFolded(_ folded: Bool, then: (() -> Void)? = nil) {
        guard folded != tripsFolded else { then?(); return }
        if !folded { tripsRestShown = true }
        withAnimation(reduceMotion ? nil : ArcTheme.fold, completionCriteria: .logicallyComplete) {
            tripsFolded = folded
        } completion: {
            guard tripsFolded == folded else { return }
            if folded {
                tripsRestShown = false
                // The one-journey fold can run under an open detail, whose
                // trip owns the camera.
                if detailFlight == nil { applyCameraForCurrentTab() }
            }
            then?()
        }
    }

    private func recenterOnDetail() {
        guard let flight = detailFlight, let layout = tripsLayout else { return }
        groundViewTask?.cancel()
        groundViewTask = nil
        controller.clearGateMarker()
        controller.focus(on: flight, band: layout.band(coverTop: panelTop ?? layout.panelOpeningTop(headerHeight: panelHeaderHeight)),
                         animated: !reduceMotion)
    }

    /// The centre pill speaks for a flight only once its glide has landed,
    /// and goes back to "My Trips" the moment a close begins.
    private var tripsLiveFlight: Flight? {
        guard detailTab == .myFlights, transition.phase == .detail,
              detailFriend == nil, detailInvite == nil else { return nil }
        return detailFlight
    }

    private var tripsShareFlight: Flight? {
        if detailTab == .myFlights, let open = detailFlight {
            // An invite preview isn't the user's trip yet, and sharing some
            // other trip from over it would be the wrong one.
            if detailInvite != nil { return nil }
            if detailFriend == nil { return open }
        }
        // The trip you're ON if there is one, else the NEXT one — never a leg
        // that already landed.
        let listed = MyFlightsView.listed(Array(allFlights))
        return listed.first(where: \.isActive) ?? listed.first(where: \.isUpcoming)
    }

    /// The accessory: adding a flight is always available, and a copied flight
    /// number folds in BESIDE it rather than replacing it. Making the paste
    /// offer take over the slot meant that whenever something was on the
    /// clipboard there was no way to add a flight at all.
    private var bottomAccessory: some View {
        HStack(spacing: 12) {
            Button { showAdd = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .semibold))
                    Text("Add a trip").font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if offeredPasteChange != nil, !showAdd, detailFlight == nil {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(ArcTheme.brand)
                Text("Add from clipboard")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ArcTheme.brand)
                    .lineLimit(1)
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
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
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
            // Already tracked: the useful answer to "paste LX1413" is that
            // flight, not a button that silently vanishes.
            if let existing = allFlights.first(where: {
                $0.flightNumber.replacingOccurrences(of: " ", with: "").uppercased() == code
            }) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                _ = show(existing)
                return
            }
            clipboardQuery = code
        } else {
            // Not a bare number — let the Add screen's parser take the whole thing.
            clipboardQuery = text
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showAdd = true
    }

}

/// The floating My Trips surface's hooks, kept out of the root's builders
/// (they sit at the type checker's limit). `onFirstFrame` fires once: one
/// camera move at launch, not one per measurement.
private struct MyTripsSurfaceHooks: ViewModifier {
    let journeyCount: Int
    let detailID: UUID?
    /// The layout exists and the folded stack has reported its height.
    let firstFrameReady: Bool
    let onJourneyCount: (Int) -> Void
    let onDetailSettled: () async -> Void
    let onFirstFrame: () -> Void

    @State private var framed = false

    func body(content: Content) -> some View {
        content
            .onChange(of: journeyCount) { _, count in onJourneyCount(count) }
            .task(id: detailID) {
                guard detailID != nil else { return }
                await onDetailSettled()
            }
            .onChange(of: firstFrameReady, initial: true) { _, ready in
                guard ready, !framed else { return }
                framed = true
                onFirstFrame()
            }
    }
}

/// Hidden until the folded stack has reported its height: before that the
/// pill row sits on the accessory for a frame. Appears at once, never fades.
private struct UntilMeasured: ViewModifier {
    let measured: Bool
    func body(content: Content) -> some View {
        content
            .opacity(measured ? 1 : 0)
            .animation(nil, value: measured)
    }
}

/// Empty accessory content still reserves a glass capsule. Disable the native
/// slot itself on supported systems; iOS 26.0 retains the working add action.
private struct JourneyAccessory<Accessory: View>: ViewModifier {
    let isEnabled: Bool
    let accessory: Accessory

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: isEnabled) { accessory }
        } else {
            content.tabViewBottomAccessory { accessory }
        }
    }
}
