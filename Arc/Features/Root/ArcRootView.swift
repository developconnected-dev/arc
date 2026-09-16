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
    /// The journey the folded stack is on (docs/superpowers/specs/2026-09-15-journey-stack-design.md).
    @State private var tripsPage = 0
    /// Journeys, or the invites behind the bell: the stack shows one or the
    /// other, and the bell swaps them.
    @State private var tripsMode: TripsMode = .trips
    /// The invite the stack is on while it is showing invites. Entering
    /// invites always starts at the first one; the journey page is kept.
    @State private var tripsInvitePage = 0
    /// Which invites have been on screen, for the bell's red dot.
    @State private var inviteReads = InviteReadStore.shared
    /// The root reads its `settledHeight` only; `liveRise` belongs to leaves.
    @State private var tripsStackMotion = JourneyStackMotion()
    @State private var tripsFlipRequest: Int?
    /// The invites (and error) above the stack, with the gap under them.
    @State private var tripsChromeHeight: CGFloat = 0
    /// The camera's pending move onto the journey the stack last settled on.
    @State private var tripsFocusTask: Task<Void, Never>?
    /// The whole stack's height, every journey included: an unfolded stack
    /// grows up from the bottom only this far.
    @State private var tripsContentHeight: CGFloat = 0
    @State private var tripsLayout: MyTripsLayout?
    /// Friends floats the same way (docs/superpowers/specs/2026-09-16-friends-floating-design.md),
    /// with the same state for its own stack: flights, or the friend
    /// requests behind its bell.
    @State private var friendsFolded = !ProcessInfo.processInfo.arguments.contains("-sheetLarge")
    @State private var friendsPage = 0
    @State private var friendsMode: FriendsMode = .flights
    @State private var friendsRequestPage = 0
    @State private var requestReads = InviteReadStore.friendRequests
    @State private var friendsMotion = JourneyStackMotion()
    @State private var friendsFlipRequest: Int?
    @State private var friendsChromeHeight: CGFloat = 0
    @State private var friendsContentHeight: CGFloat = 0
    @State private var friendsFocusTask: Task<Void, Never>?
    @State private var friendsLayout: MyTripsLayout?
    /// The intro / profile setup panel's settled top edge, apart from the
    /// detail's: signing in must not leave the detail opening where the
    /// intro was dragged to.
    @State private var friendsIntroPanelTop: CGFloat?
    /// The detail panel's settled top edge; nil opens at 58 %.
    @State private var panelTop: CGFloat?
    @State private var panelHeaderHeight: CGFloat = 260
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
        // (tab content, map background and the + bubble live in `tabs` — split
        // out so the modifier chain below stays inside the type checker's budget.)

        .sheet(isPresented: $showAdd) {
            // The moment is claimed at the save — the map is visible behind
            // this sheet as it slides away, and must already be hiding the
            // settled line and framing the route — and the draw starts once
            // the sheet is out of the way.
            AddFlightView(initialQuery: addInitialQuery,
                          onAdded: { added in holdTrips([added]) })
            .presentationDetents([.large])
            .onDisappear {
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
                drainPendingOpen()
                // A scene can be rebuilt with a new window; the watcher
                // re-attaches to whichever one is key now.
                IdleWatcher.shared.start()
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
            // Watches the window for touches, so the stack knows when the
            // screen has gone quiet (IdleWatcher).
            IdleWatcher.shared.start()
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
            if ProcessInfo.processInfo.arguments.contains("-openAdd") { showAdd = true }
            drainPendingOpen()
        }
    }

    private func focusPresentedTrip() async {
        guard let id = mapFocusID, let flight = detailFlight, flight.id == id else { return }
        // Start on the next turn after the card handoff, never during its travel.
        await Task.yield()
        guard !Task.isCancelled, mapFocusID == id, detailFlight?.id == id else { return }
        if let layout = floatingLayout(detailTab) {
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
        // And My Trips brings that row into view once the route has drawn:
        // a folded stack flips to its journey, an unfolded list scrolls to it.
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
            // band above what covers the map: the folded stack, or the
            // intro's panel before signing in.
            let coords = friendsStore.mapOverlays.flatMap { [$0.dep, $0.arr] }
            guard !coords.isEmpty else { return }
            if let band = friendsBand {
                controller.frame(coords, band: band)
            } else {
                controller.frameInUpperHalf(coords)
            }
            return
        }
        if tab == .myFlights, let layout = tripsLayout {
            // Framed for the folded stack: unfolded, the cards cover the map
            // anyway, and the fold refits once it has settled.
            let coverTop = layout.listTop(folded: true, foldedHeight: tripsFoldedHeight, contentHeight: tripsContentHeight)
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
            guard !Task.isCancelled, groundViewStillWanted(for: flight) else { return }
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
            guard !Task.isCancelled, groundViewStillWanted(for: flight) else { return }
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

    /// A ground view's answer still has a detail to belong to: the same trip
    /// is open and not closing. A close has already cleared the gate marker
    /// and restored the map style; an answer landing after it would leave
    /// satellite imagery and plane polling behind with no detail (and no
    /// Back button any more) to leave them from.
    private func groundViewStillWanted(for flight: Flight) -> Bool {
        detailFlight?.id == flight.id && transition.phase != .closing
    }

    /// Terminal map / My plane need the map: a panel dragged taller than
    /// its opening height comes back down, on the next turn after the camera
    /// sets off (`lowerPanelForGroundViewAfterMapUpdate`).
    /// A detail in Passport's sheet drops the sheet to medium, as it always has.
    private func lowerPanelForGroundView() {
        guard let layout = floatingLayout(detailTab) else {
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
        guard let flight = detailFlight else { return }
        DispatchQueue.main.async {
            guard groundViewStillWanted(for: flight) else { return }
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
        heroOrigin = heroRowOrigin(source.key, on: tab)
        heroDestination = nil
        heroTravelling = heroOrigin == nil ? nil : source
        transition.open()
    }

    /// Where the row to glide from is — but only if it's on screen. The
    /// frames outlive the rows: a card folded away still has one, and a glide
    /// from it would start out of nowhere, below the stack.
    ///
    /// Folded, only the stack's current card is on screen — and only one kind
    /// of card is showing at all: an invite's frame is stale the moment the
    /// bell swaps back to the journeys, and a journey's while the invites are
    /// up. A list card also keeps the frame it last reported while unfolded,
    /// which can lie inside the folded band: a trip opened from a widget,
    /// notification or pasted number would glide from a card that isn't there.
    private func heroRowOrigin(_ key: String, on surface: ArcTab?) -> CGRect? {
        guard let rect = heroFrames.rows[key] else { return nil }
        switch surface {
        case .myFlights: return tripsRowOrigin(key, rect: rect)
        case .friends: return friendsRowOrigin(key, rect: rect)
        default: return rect
        }
    }

    private func tripsRowOrigin(_ key: String, rect: CGRect) -> CGRect? {
        guard let layout = tripsLayout else { return rect }
        let isInvite = friendsStore.tripInvites.contains { $0.id == key }
        guard isInvite == (tripsMode == .invites) else { return nil }
        if tripsFolded {
            switch tripsMode {
            case .trips:
                let journeys = MyFlightsView.journeys(Array(allFlights))
                guard journeys.indices.contains(tripsPage),
                      journeys[tripsPage].legs.contains(where: { $0.id.uuidString == key }) else { return nil }
            case .invites:
                let invites = friendsStore.tripInvites
                guard invites.indices.contains(tripsInvitePage),
                      invites[tripsInvitePage].id == key else { return nil }
            }
        }
        return Self.visibleSlice(rect, layout: layout, folded: tripsFolded, foldedHeight: tripsFoldedHeight,
                                 contentHeight: tripsContentHeight, motion: tripsStackMotion)
    }

    /// The same rule on Friends: only friends' flights have a detail, only
    /// while they are the cards showing, and folded only the current one.
    private func friendsRowOrigin(_ key: String, rect: CGRect) -> CGRect? {
        guard let layout = friendsLayout else { return rect }
        guard friendsMode == .flights else { return nil }
        if friendsFolded, friendsStackKey != key { return nil }
        return Self.visibleSlice(rect, layout: layout, folded: friendsFolded, foldedHeight: friendsFoldedHeight,
                                 contentHeight: friendsContentHeight, motion: friendsMotion)
    }

    /// `rect` if it lies inside the list's visible slice. The live top:
    /// mid-swipe the stack's edge is off its resting place. A tap can't open
    /// mid-swipe (taps are off while holding), but a widget, notification or
    /// link can.
    private static func visibleSlice(_ rect: CGRect, layout: MyTripsLayout, folded: Bool, foldedHeight: CGFloat,
                                     contentHeight: CGFloat, motion: JourneyStackMotion) -> CGRect? {
        let top = layout.listTop(folded: folded, foldedHeight: foldedHeight, contentHeight: contentHeight)
            - JourneyStackPaging.edgeRise(liveRise: motion.liveRise, restHeight: foldedHeight,
                                          room: layout.listBottom - layout.unfoldedListTop)
        let shown = (min(top, layout.listBottom) - 1)...(layout.listBottom + 1)
        return shown.contains(rect.minY) && shown.contains(rect.maxY) ? rect : nil
    }

    /// The floating surface a detail on `surface` opens in, once measured.
    /// Nil for Passport, whose detail lives in the sheet.
    private func floatingLayout(_ surface: ArcTab?) -> MyTripsLayout? {
        switch surface {
        case .myFlights: tripsLayout
        case .friends: friendsLayout
        default: nil
        }
    }

    /// Records the header's height and returns how far that moved the
    /// panel's opening top — non-zero only where the header rule binds
    /// (a short screen, large type) and the panel hasn't been dragged.
    @discardableResult
    private func learnPanelHeader(_ measured: CGRect) -> CGFloat {
        guard panelTop == nil, let layout = floatingLayout(detailTab) else {
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
            if floatingLayout(detailTab) != nil, let key, let header = heroFrames.details[key] {
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
        guard floatingLayout(detailTab) != nil, let measured = heroFrames.details[source.key] else {
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
            heroOrigin = heroRowOrigin(source.key, on: detailTab)
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
        TabView(selection: tabSelection) {
                // No badge for open invites: the bell above the stack carries
                // them now, with its own unread dot.
                Tab(ArcTab.myFlights.title, systemImage: ArcTab.myFlights.icon, value: TabSelection.tab(.myFlights)) {
                    myTripsSurface
                }
                Tab(ArcTab.friends.title, systemImage: ArcTab.friends.icon, value: TabSelection.tab(.friends)) {
                    friendsSurface
                }
                Tab(ArcTab.passport.title, systemImage: ArcTab.passport.icon, value: TabSelection.tab(.passport)) {
                    tabSurface(.passport) { PassportView { openDetail($0) } }
                }
                // iOS 26's separated tab: a round glass bubble beside the bar,
                // the native home for a persistent primary action (the
                // accessory bar above the bar is gone). Its content is never
                // shown — choosing it opens the Add sheet and leaves the
                // selection where it was (`tabSelection`).
                Tab(TabSelection.addTitle, systemImage: TabSelection.addIcon, value: TabSelection.add, role: .search) {
                    EmptyView()
                }
            }
    }

    /// What the TabView is actually driven by. Selecting the + never moves the
    /// selection: the user stays on the tab they were on and the Add sheet
    /// comes up over it.
    private var tabSelection: Binding<TabSelection> {
        Binding(get: { .tab(tab) },
                set: { selected in
                    switch selected {
                    case .tab(let picked): tab = picked
                    case .add: showAdd = true
                    }
                })
    }

    /// Everything that belongs to the map, built once behind the tabs.
    private var mapLayer: some View {
        ZStack(alignment: .top) {
            ArcMapView(flights: mapFlights, controller: controller,
                       friendOverlays: tab == .friends ? friendsStore.mapOverlays : [])
                .ignoresSafeArea()

            // The floating tabs carry map style and weather in their top row's
            // menu and recenter above their cards (MapTopBar); Passport's
            // sheet keeps the column.
            if tab == .passport {
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
            // A picture of the card in motion, not a second copy of its
            // buttons and labels: VoiceOver and UI queries see the real row
            // and header only.
            .accessibilityHidden(true)
        }
    }

    /// Passport shows a draggable sheet over the shared map. The sheet still
    /// slides away while a detail or add sheet is up, so two sheets are never
    /// stacked. My Trips and Friends float instead (`myTripsSurface`,
    /// `friendsSurface`).
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
                            // As on My Trips: a closing detail takes no touches.
                            .allowsHitTesting(transition.phase != .closing)
                    }
                }
                .overlay {
                    if active {
                        heroOverlay(glass: false) { size, rowHeight in Morph.target(in: size, rowHeight: rowHeight) }
                    }
                }
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

    /// The folded overlay's height: what sits above the stack plus the
    /// current journey's card at rest. Changes once per settle, not per frame.
    private var tripsFoldedHeight: CGFloat { tripsChromeHeight + tripsStackMotion.settledHeight }

    /// My Trips: no sheet. The map fills the screen, the trips float over it
    /// as glass cards, and a trip opens in a glass panel the row glides into.
    /// Everything about that is `FloatingSurface`'s; this is what My Trips
    /// puts on it.
    private var myTripsSurface: some View {
        // Once per root pass: grouping runs the connection planner.
        let journeyCount = MyFlightsView.journeys(Array(allFlights)).count
        return FloatingSurface(
            title: "My Trips",
            liveFlight: tripsLiveFlight,
            shareFlight: tripsShareFlight,
            menuExtras: { EmptyView() },
            controller: controller,
            map: mapLayer,
            folded: tripsFolded,
            motion: tripsStackMotion,
            chromeHeight: tripsChromeHeight,
            contentHeight: tripsContentHeight,
            stackCount: tripsMode == .invites ? friendsStore.tripInvites.count : journeyCount,
            foldIdentifier: "trips-fold-toggle",
            onFold: { folded in setTripsFolded(folded) },
            content: { layout in tripsList(layout) },
            // My Trips keeps nothing between its cards and the buttons.
            extraRowHeight: 0,
            extraRow: { EmptyView() },
            bell: tripsBell,
            showsRecenter: !mapFlights.isEmpty,
            onRecenter: { applyCameraForCurrentTab() },
            panelTop: $panelTop,
            panelHeaderHeight: panelHeaderHeight,
            onPanelRecenter: { recenterOnDetail() },
            panel: { detailPanelContent },
            transition: surfaceTransition(.myFlights),
            heroOverlay: { top in
                heroOverlay(glass: true) { size, rowHeight in
                    Morph.panelTarget(panelTop: top, width: size.width, rowHeight: rowHeight)
                }
            },
            measuredLayout: $tripsLayout,
            coveredBySheet: showAdd,
            hooks: tripsHooks(journeyCount: journeyCount))
    }

    /// The root's share of the glide: one transition, whichever tab it is on.
    private func surfaceTransition(_ surface: ArcTab) -> FloatingSurfaceTransition {
        let onSurface = detailTab == surface && tab == surface
        return FloatingSurfaceTransition(active: onSurface,
                                         detailOpen: onSurface && detailFlight != nil,
                                         phase: transition.phase,
                                         request: transition.request,
                                         progress: $heroProgress,
                                         frames: heroFrames,
                                         travellingKey: heroTravelling?.key,
                                         prepare: prepareTransition,
                                         finish: finishTransition)
    }

    private func tripsHooks(journeyCount: Int) -> FloatingSurfaceHooks {
        FloatingSurfaceHooks(itemCount: journeyCount,
                             onItemCount: { count in
                                 // Only the pill folds, and it is gone with one journey left.
                                 if count <= 1, !tripsFolded { setTripsFolded(true) }
                             },
                             bellItems: friendsStore.tripInvites.map(\.id),
                             onBellItems: { ids in tripInvitesChanged(ids) },
                             detailID: detailTab == .myFlights ? detailFlight?.id : nil,
                             onDetailSettled: learnHeaderWithoutGlide,
                             onFirstFrame: refitTripsForFirstFrame)
    }

    /// An opening with no glide (Reduce Motion, one detail replacing another)
    /// never runs `prepareTransition`: learn the new header once it has laid out.
    private func learnHeaderWithoutGlide() async {
        try? await Task.sleep(for: .milliseconds(16))
        guard !Task.isCancelled, transition.request == nil, floatingLayout(detailTab) != nil,
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

    /// Nothing in front of the trips: the folded stack may nudge to show it
    /// can be flipped. Folded-ness and the second journey are the stack's own
    /// conditions (`JourneyStack.hintsEnabled`).
    private var tripsHintsEnabled: Bool {
        tab == .myFlights && detailFlight == nil && !showAdd && scenePhase == .active
    }

    /// The cards themselves. The fixed frame, the mask that reveals them and
    /// the fades are the surface's (`FloatingSurface.list`); the layout is
    /// here for the room above short content.
    private func tripsList(_ layout: MyTripsLayout) -> some View {
        MyFlightsView(onSelect: { openDetail($0) },
                      onAdd: { showAdd = true },
                      onImported: { imported in acceptedInvite(imported) },
                      onPreview: { item, flight in openInvitePreview(item, flight) },
                      landed: landedTrips,
                      folded: tripsFolded,
                      revealing: controller.isRevealingRoutes,
                      onContentHeight: { tripsContentHeight = $0 },
                      page: $tripsPage,
                      motion: tripsStackMotion,
                      flipRequest: tripsFlipRequest,
                      onFlipRequestHandled: { tripsFlipRequest = nil },
                      onChromeHeight: { tripsChromeHeight = $0 },
                      topSpacer: layout.contentTopSpacer(contentHeight: tripsContentHeight),
                      onRevealJourney: { tripsFlipRequest = $0 },
                      onStackSettled: { stackSettled(on: $0) },
                      hintsEnabled: tripsHintsEnabled,
                      mode: tripsMode,
                      invitePage: $tripsInvitePage,
                      onInviteSettled: { id in inviteReads.markSeen(id) })
    }

    /// The invites' bell, only there while an invite is open: it swaps the
    /// stack to the invites and back, and carries the unread dot. The button
    /// is the surface's; what it means is here.
    private var tripsBell: FloatingSurfaceBell? {
        guard !friendsStore.tripInvites.isEmpty else { return nil }
        let showing = tripsMode == .invites
        return FloatingSurfaceBell(
            showing: showing,
            unread: friendsStore.tripInvites.filter { !inviteReads.seen.contains($0.id) }.count,
            identifier: "trips-invites-bell",
            label: showing ? "Back to your trips" : "Trip invitations",
            action: {
                let target: TripsMode = showing ? .trips : .invites
                setTripsMode(target)
            })
    }

    /// The bell's swap: the two stacks crossfade in place while the frame's
    /// height springs from one card to the other. Nothing else moves — the
    /// camera stays where it is, as it does through a fold.
    private func setTripsMode(_ mode: TripsMode, then next: (() -> Void)? = nil) {
        guard mode != tripsMode else { next?(); return }
        // Mid-swipe or mid-settle the stack's page and height are still the
        // old ones: land it first, as Show More does.
        tripsStackMotion.comeToRest()
        if mode == .invites {
            // The invites always open on the first one; the journey the user
            // was on is kept for the way back.
            tripsInvitePage = 0
            markInviteSeen(at: 0)
        }
        // The height arrives a beat later, from the incoming card's own
        // measurement: this is what makes it spring rather than jump.
        if !reduceMotion { tripsStackMotion.beginSwap(ArcTheme.fold) }
        withAnimation(reduceMotion ? nil : ArcTheme.fold, completionCriteria: .logicallyComplete) {
            tripsMode = mode
        } completion: {
            next?()
        }
    }

    /// The invite showing when the invites open counts as seen too — the
    /// stack only reports the ones it flips to.
    private func markInviteSeen(at index: Int) {
        let invites = friendsStore.tripInvites
        guard invites.indices.contains(index) else { return }
        inviteReads.markSeen(invites[index].id)
    }

    /// An accepted invite is an import: the trip is the user's now, so the
    /// stack belongs back on the journeys BEFORE the route draws and it flips
    /// to the new one — one movement at a time, and never a flip behind a
    /// stack of invites.
    private func acceptedInvite(_ flight: Flight) {
        setTripsMode(.trips) { revealTrips([flight]) }
    }

    /// The open invites changed. Nothing left to answer while they are
    /// showing means the stack comes back by itself, on the same motion the
    /// bell uses — and the bell goes with them.
    private func tripInvitesChanged(_ ids: [String]) {
        // Only ever pruned against a list that has something in it: a cold
        // launch starts empty and would otherwise forget every invite the
        // traveller has already seen.
        if !ids.isEmpty { inviteReads.prune(keeping: ids) }
        if ids.isEmpty {
            if tripsMode == .invites { setTripsMode(.trips) }
        } else if tripsInvitePage >= ids.count {
            tripsInvitePage = ids.count - 1
        }
    }

    /// What My Trips and Friends put in the floating panel: the open detail,
    /// the user's own trip, an invite's preview or a friend's flight. The
    /// panel itself — its drag, its glass, its recenter circle and its
    /// placement — is the surface's.
    @ViewBuilder
    private var detailPanelContent: some View {
        if let flight = detailFlight {
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
                // Its own tiny element: set on the detail, the identifier spread
                // to the X in its offset overlay and UI tests tapped the detail's centre.
                .background {
                    Color.clear.frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityIdentifier(transition.request == nil ? "trip-detail-ready" : "trip-detail-transition")
                }
        }
    }

    /// Folding and unfolding ride one spring; only the list's mask and the
    /// pill row move (the list scrolls itself around the current journey
    /// first). The camera reframes only once a fold has settled — never two
    /// movements at once.
    private func setTripsFolded(_ folded: Bool) {
        guard folded != tripsFolded else { return }
        // Mid-settle or mid-swipe, the page and the stack's height are still
        // the old ones: land first, so the list aligns to what's showing.
        tripsStackMotion.comeToRest()
        withAnimation(reduceMotion ? nil : ArcTheme.fold, completionCriteria: .logicallyComplete) {
            tripsFolded = folded
        } completion: {
            guard tripsFolded == folded, folded else { return }
            // The one-journey fold can run under an open detail, whose
            // trip owns the camera.
            if detailFlight == nil { applyCameraForCurrentTab() }
        }
    }

    /// The map follows the stack, and only the stack's own flips: a page
    /// index that moved because the list changed (a delete, a flight going
    /// active) keeps the list change's refit. Quick flips move the camera
    /// once, onto the journey the last one settled on: the wait restarts
    /// while the stack is moving again, since a flip that begins inside it
    /// would otherwise land under a camera already on its way.
    private func stackSettled(on journeyID: UUID) {
        tripsFocusTask?.cancel()
        tripsFocusTask = Task { @MainActor in
            repeat {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            } while !tripsStackMotion.isAtRest
            focusTripsJourney(journeyID)
        }
    }

    /// Frames a journey's routes in the band above the folded stack.
    /// Recenter and a fold still fit every trip.
    private func focusTripsJourney(_ journeyID: UUID) {
        guard tab == .myFlights, tripsFolded, detailFlight == nil, !controller.isRevealingRoutes,
              let layout = tripsLayout,
              let journey = MyFlightsView.journeys(Array(allFlights)).first(where: { $0.id == journeyID })
        else { return }
        let coords = journey.legs.flatMap { RouteReveal.geometry(for: $0) }
        guard !coords.isEmpty else { return }
        let coverTop = layout.listTop(folded: true, foldedHeight: tripsFoldedHeight, contentHeight: tripsContentHeight)
        controller.frame(coords, band: layout.band(coverTop: coverTop), padding: 1.3, animated: !reduceMotion)
    }

    private func recenterOnDetail() {
        guard let flight = detailFlight, let layout = floatingLayout(detailTab) else { return }
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

    // MARK: - Friends, floating

    /// Signed in, or a demo feed standing in for it: the cards, the chips and
    /// the bell. Before that, the intro and the profile setup stand in the
    /// panel instead.
    private var friendsSignedIn: Bool {
        guard !DemoSeed.isFriendsSignedOutRequested else { return false }
        return DemoSeed.isFriendsRequested || supabase.isSignedIn
    }

    private var friendsFoldedHeight: CGFloat { friendsChromeHeight + friendsMotion.settledHeight }

    /// Friends: no sheet. Friends' flights float over the globe in the same
    /// grammar as My Trips — one card at a time, the chips directly above,
    /// requests behind the bell (docs/superpowers/specs/2026-09-16-friends-floating-design.md).
    /// `FriendsListView` keeps the feed, the filter and the sheets; the
    /// surface is `FloatingSurface`'s.
    private var friendsSurface: some View {
        FriendsListView(onSelect: { openFriendFlight($0) }) { feed in
            friendsFloating(feed)
                .onChange(of: feed.flights.map(\.id), initial: true) { _, ids in friendsStackIDs = ids }
        }
    }

    private func friendsFloating(_ feed: FriendsFeed) -> some View {
        let signedIn = friendsSignedIn
        let requests = friendsStore.requests
        return FloatingSurface(
            title: "Friends",
            liveFlight: friendsLiveFlight,
            shareFlight: nil,
            menuExtras: {
                if signedIn {
                    Button(action: feed.onManage) {
                        Label("Manage friends and groups", systemImage: "person.2")
                    }
                }
            },
            controller: controller,
            map: mapLayer,
            folded: friendsFolded,
            motion: friendsMotion,
            chromeHeight: friendsChromeHeight,
            contentHeight: friendsContentHeight,
            stackCount: friendsMode == .requests ? requests.count : feed.flights.count,
            foldIdentifier: "friends-fold-toggle",
            onFold: { folded in setFriendsFolded(folded) },
            content: { layout in friendsList(feed, layout: layout) },
            extraRowHeight: signedIn ? FriendFilterChips.height : 0,
            extraRow: {
                FriendFilterChips(filter: feed.filter, groups: feed.groups, friends: feed.friends,
                                  onAdd: feed.onAdd, onManage: feed.onManage)
            },
            bell: signedIn ? friendsBell(requests) : nil,
            showsRecenter: !friendsStore.mapOverlays.isEmpty,
            onRecenter: { applyCameraForCurrentTab() },
            panelTop: signedIn ? $panelTop : $friendsIntroPanelTop,
            panelHeaderHeight: signedIn ? panelHeaderHeight : FriendsSignInPanel.headerHeight,
            onPanelRecenter: signedIn ? { recenterOnDetail() } : nil,
            panel: {
                if signedIn { detailPanelContent } else { FriendsSignInPanel() }
            },
            standingPanel: !signedIn,
            transition: surfaceTransition(.friends),
            heroOverlay: { top in
                heroOverlay(glass: true) { size, rowHeight in
                    Morph.panelTarget(panelTop: top, width: size.width, rowHeight: rowHeight)
                }
            },
            measuredLayout: $friendsLayout,
            coveredBySheet: showAdd,
            hooks: friendsHooks(feed, requests: requests))
    }

    private func friendsHooks(_ feed: FriendsFeed, requests: [FriendRequest]) -> FloatingSurfaceHooks {
        FloatingSurfaceHooks(itemCount: feed.flights.count,
                             onItemCount: { count in friendsCountChanged(count) },
                             bellItems: requests.map(\.id),
                             onBellItems: { ids in friendRequestsChanged(ids) },
                             detailID: detailTab == .friends ? detailFlight?.id : nil,
                             onDetailSettled: learnHeaderWithoutGlide,
                             onFirstFrame: refitFriendsForFirstFrame)
    }

    /// The cards themselves; the frame, the mask and the fades are the
    /// surface's.
    private func friendsList(_ feed: FriendsFeed, layout: MyTripsLayout) -> some View {
        FriendsFloatingList(feed: feed,
                            onSelect: { openFriendFlight($0) },
                            folded: friendsFolded,
                            onContentHeight: { friendsContentHeight = $0 },
                            page: $friendsPage,
                            motion: friendsMotion,
                            flipRequest: friendsFlipRequest,
                            onFlipRequestHandled: { friendsFlipRequest = nil },
                            onChromeHeight: { friendsChromeHeight = $0 },
                            topSpacer: layout.contentTopSpacer(contentHeight: friendsContentHeight),
                            onFlightSettled: { id in
                                if let group = feed.flights.first(where: { $0.id == id }) { friendsStackSettled(on: group) }
                            },
                            hintsEnabled: tab == .friends && detailFlight == nil && !showAdd && scenePhase == .active,
                            mode: friendsMode,
                            requestPage: $friendsRequestPage,
                            onRequestSettled: { id in requestReads.markSeen(id) })
    }

    /// The friend-requests bell, only there while a request is open: My
    /// Trips' invite bell, answering to friend requests.
    private func friendsBell(_ requests: [FriendRequest]) -> FloatingSurfaceBell? {
        guard !requests.isEmpty else { return nil }
        let showing = friendsMode == .requests
        return FloatingSurfaceBell(
            showing: showing,
            unread: requests.filter { !requestReads.seen.contains($0.id) }.count,
            identifier: "friends-requests-bell",
            label: showing ? "Back to friends' flights" : "Friend requests",
            action: {
                let target: FriendsMode = showing ? .flights : .requests
                setFriendsMode(target)
            })
    }

    /// The bell's swap, as `setTripsMode` does it: the two stacks crossfade
    /// in place while the frame's height springs; the camera stays.
    private func setFriendsMode(_ mode: FriendsMode) {
        guard mode != friendsMode else { return }
        friendsMotion.comeToRest()
        if mode == .requests {
            // The requests always open on the first one, which counts as
            // seen: the stack only reports the ones it flips to.
            friendsRequestPage = 0
            if let first = friendsStore.requests.first { requestReads.markSeen(first.id) }
        }
        if !reduceMotion { friendsMotion.beginSwap(ArcTheme.fold) }
        withAnimation(reduceMotion ? nil : ArcTheme.fold) {
            friendsMode = mode
        }
    }

    /// The open requests changed: nothing left to answer while they are
    /// showing brings the flights back by themselves, and the bell goes.
    private func friendRequestsChanged(_ ids: [String]) {
        // Pruned only against a list with something in it: a cold launch
        // starts empty and would forget every request already seen.
        if !ids.isEmpty { requestReads.prune(keeping: ids) }
        if ids.isEmpty {
            if friendsMode == .requests { setFriendsMode(.flights) }
        } else if friendsRequestPage >= ids.count {
            friendsRequestPage = ids.count - 1
        }
    }

    /// The filter or the feed changed how many flights there are: one left
    /// folds the list (the pill is gone with it), and the globe, which
    /// mirrors the filter, is framed again.
    private func friendsCountChanged(_ count: Int) {
        if count <= 1, !friendsFolded, friendsMode == .flights { setFriendsFolded(true) }
        if tab == .friends, detailFlight == nil, friendsFolded { applyCameraForCurrentTab() }
    }

    private func setFriendsFolded(_ folded: Bool) {
        guard folded != friendsFolded else { return }
        friendsMotion.comeToRest()
        withAnimation(reduceMotion ? nil : ArcTheme.fold, completionCriteria: .logicallyComplete) {
            friendsFolded = folded
        } completion: {
            guard friendsFolded == folded, folded else { return }
            if detailFlight == nil { applyCameraForCurrentTab() }
        }
    }

    private func refitFriendsForFirstFrame() {
        guard tab == .friends, detailFlight == nil else { return }
        applyCameraForCurrentTab()
    }

    /// The card the folded stack shows, by its hero key.
    private var friendsStackKey: String? {
        friendsStackIDs.indices.contains(friendsPage) ? friendsStackIDs[friendsPage] : nil
    }

    /// The flights the stack pages, by id and in its order — the feed itself
    /// is `FriendsListView`'s; the root keeps only this, for the glide.
    @State private var friendsStackIDs: [String] = []

    /// The map follows the stack's own flips, once it is still: the same
    /// debounce as My Trips (`stackSettled`).
    private func friendsStackSettled(on group: FriendFlightGroup) {
        friendsFocusTask?.cancel()
        friendsFocusTask = Task { @MainActor in
            repeat {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            } while !friendsMotion.isAtRest
            focusFriendsFlight(group)
        }
    }

    /// Frames a friend's flight in the band above the folded stack.
    private func focusFriendsFlight(_ group: FriendFlightGroup) {
        guard tab == .friends, friendsFolded, detailFlight == nil, let band = friendsBand else { return }
        let coords = RouteReveal.geometry(for: friendsStore.transientFlight(for: group.representative))
        guard !coords.isEmpty else { return }
        controller.frame(coords, band: band, padding: 1.3, animated: !reduceMotion)
    }

    /// The map above whatever covers it on Friends: the folded stack with
    /// the chips and the buttons over it, or — signed out — the panel.
    private var friendsBand: MapBand? {
        guard let layout = friendsLayout else { return nil }
        guard friendsSignedIn else {
            return layout.band(coverTop: friendsIntroPanelTop
                               ?? layout.panelOpeningTop(headerHeight: FriendsSignInPanel.headerHeight))
        }
        let listTop = layout.listTop(folded: true, foldedHeight: friendsFoldedHeight, contentHeight: friendsContentHeight)
        return layout.band(coverTop: listTop - MyTripsLayout.gap - FriendFilterChips.height)
    }

    /// The centre pill speaks for a friend's flight once its glide has landed.
    private var friendsLiveFlight: Flight? {
        guard detailTab == .friends, transition.phase == .detail, detailFriend != nil else { return nil }
        return detailFlight
    }

    /// The accessory: adding a flight is always available, and a copied flight
    /// number folds in BESIDE it rather than replacing it. Making the paste
    /// offer take over the slot meant that whenever something was on the
    /// clipboard there was no way to add a flight at all.
}
