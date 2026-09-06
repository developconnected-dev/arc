import SwiftUI
import MapKit
import SwiftData

struct ArcRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
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
    /// The in-flight "Terminal Map"/"My plane" setup (a network fetch, then a
    /// camera dive). Cancelled when its detail closes — otherwise the answer
    /// arrived seconds after dismissal and hijacked the map with a gate view
    /// for a flight that was no longer open.
    @State private var groundViewTask: Task<Void, Never>?
    /// The sheet height before a friend-route zoom shrank it to .small.
    @State private var detentBeforeFocus: SheetDetent?
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
    /// A flight-list change that happened while a route was drawing itself
    /// on and was not the change the reveal was for — a swipe-delete, a trip
    /// that arrived by another path. Its refit is owed once the reveal ends.
    @State private var refitOwedAfterReveal = false


    /// Test hooks for headless screenshots.
    private var addInitialQuery: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-addQuery"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    var body: some View {
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
        // Dismissing the flight leaves its ground view too — otherwise the map
        // stayed stuck in terminal mode with a Back button and no flight.
        .sheet(item: $detailFlight,
               onDismiss: {
                   groundViewTask?.cancel()
                   groundViewTask = nil
                   controller.clearGateMarker()
                   presentQueuedDetail()
               }) { flight in
            FlightDetailView(flight: flight,
                             onShowAtGate: { f in showPlaneAtGate(f) },
                             onShowAirport: { f in showAirportView(f) },
                             onOpenFlight: { other in _ = show(other) })
                .presentationDetents([.medium, .large], selection: $detailDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
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
        .onChange(of: allFlights.map(\.id)) { previous, current in
            refitForListChange(from: previous, to: current)
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
        .modifier(RevealCameraHandback(controller: controller, settle: settleOwedRefit))
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
                if detentBeforeFocus == nil { detentBeforeFocus = detent }
                detent = .small
                controller.focusRoute(dep: route.dep, arr: route.arr, mode: route.mode)
            } else {
                // Give the sheet back its height — `detent` is shared across
                // tabs, and the sliver otherwise followed you to My Trips.
                if let restored = detentBeforeFocus { detent = restored }
                detentBeforeFocus = nil
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
            refitMapForCurrentData()
            openDetailIfPending()
            bootstrapTrackingAndWidgets()
            refreshClipboardOffer()
            if ProcessInfo.processInfo.arguments.contains("-openAdd") { showAdd = true }
            drainPendingOpen()
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

    /// The refit that hangs off a flight-list change. Saving a trip is what
    /// changed the list, so while its route draws itself on the refit would
    /// frame every route the user owns and undo the fit the moment is built
    /// around. Any OTHER change in that second is deferred, not dropped.
    /// (Out of `body` — the modifier chain sits at the type-checker's limit.)
    private func refitForListChange(from previous: [UUID], to current: [UUID]) {
        if !controller.isRevealingRoutes {
            refitMapForCurrentData()
        } else if RouteReveal.listChangeNeedsRefit(
            previous: previous, current: current,
            revealing: Set(controller.routeReveals.map(\.id))) {
            refitOwedAfterReveal = true
        }
    }

    /// The reveal has handed the camera back: pay any refit it deferred.
    private func settleOwedRefit(_ revealing: Bool) {
        guard !revealing, refitOwedAfterReveal else { return }
        refitOwedAfterReveal = false
        refitMapForCurrentData()
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
        // The reveal owns the camera for the next second. Claiming the tab
        // here is what stops the tab-change hook from refitting to every
        // route the user has and fighting it.
        lastCameraTab = .myFlights
        // The route is framed in the map's upper half, which a sheet dragged
        // to full height covers entirely — an invite accepted from a
        // full-height list, or a trip added with the sheet left large, would
        // draw itself on behind it and leave the map on a camera nobody saw
        // move. Medium is the height the moment was built for: the row that
        // just landed and the route both on screen.
        if detent == .large { detent = .medium }
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

    /// The reveal handing the camera back, as a modifier for the same reason
    /// as the alert below: one more closure inline in `body`'s chain tips
    /// the type-checker over its limit.
    fileprivate struct RevealCameraHandback: ViewModifier {
        let controller: MapController
        let settle: (Bool) -> Void
        func body(content: Content) -> some View {
            content.onChange(of: controller.isRevealingRoutes) { _, revealing in settle(revealing) }
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
            detailDetent = .medium
            // The terminal map used to draw the gates and then sit there. The
            // aircraft is the reason you opened it.
            startPlaneWatch(flight)
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
        } else if let current = detailFlight, current.id != flight.id {
            // Already showing a different flight (a connection's other leg, or
            // a widget tap while detail was left open): let this one close.
            queuedDetail = flight
            detailFlight = nil
        } else {
            detailFlight = flight
        }
        return true
    }

    private func presentQueuedDetail() {
        guard let queued = queuedDetail else { return }
        // Something is still presented — wait for ITS dismissal to drain.
        guard detailFlight == nil, !showAdd else { return }
        queuedDetail = nil
        detailFlight = queued
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

    /// Native TabView: the system draws the Liquid Glass bar and owns the
    /// safe-area insets. The map is the TabView's BACKGROUND rather than content
    /// inside each tab — a background is built once, so there is still exactly
    /// one MKMapView behind all three tabs and the camera never resets on
    /// switch. Split out of `body` because the modifier chain there is long
    /// enough to defeat the type checker on its own.
    private var tabs: some View {
        TabView(selection: $tab) {
                Tab(ArcTab.myFlights.title, systemImage: ArcTab.myFlights.icon, value: ArcTab.myFlights) {
                    tabSurface {
                        MyFlightsView(onSelect: { detailFlight = $0 },
                                      onAdd: { showAdd = true },
                                      onImported: { imported in revealTrips([imported]) })
                    }
                }
                // Trips friends added for the two of you, waiting on an answer.
                .badge(friendsStore.tripInvites.count)
                Tab(ArcTab.friends.title, systemImage: ArcTab.friends.icon, value: ArcTab.friends) {
                    tabSurface { FriendsScreen() }
                }
                Tab(ArcTab.passport.title, systemImage: ArcTab.passport.icon, value: ArcTab.passport) {
                    tabSurface { PassportView { detailFlight = $0 } }
                }
            }

        // The old circular search button competed with the tab bar for the same
        // corner. The accessory is the native slot for a persistent primary
        // action, and it doubles as the home for the paste offer.
        .tabViewBottomAccessory { bottomAccessory }
    }

    /// Everything that belongs to the map, built once behind the tabs.
    private var mapLayer: some View {
        ZStack(alignment: .top) {
            ArcMapView(flights: mapFlights, controller: controller,
                       friendOverlays: tab == .friends ? friendsStore.mapOverlays : [])
                .ignoresSafeArea()

            // Hidden in the ground views: it collided with the Back button, and
            // at the gate the interesting thing is where the aircraft is on the
            // apron, not its cruise speed.
            // …and only while the fix is fresh: a speed from a position hours
            // old is not the plane's speed now.
            if tab != .friends, controller.airportView == nil, controller.gateMarker == nil,
               let active = activeFlight,
               active.liveSpeed != nil || active.liveAltitude != nil,
               let at = active.liveUpdatedAt, Date.now.timeIntervalSince(at) < 15 * 60 {
                speedAltPill(active).padding(.top, 6)
            }

            MapControls(controller: controller) { controller.fitAll(mapFlights) }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 12).padding(.top, 8)

            // Lives here rather than as an overlay on the Map: the map ignores
            // the safe area, so a top-aligned overlay on it landed under the
            // notch, unreachable — which also meant it could never be tapped
            // away. Here it sits inside the safe area, like the map controls.
            if controller.gateMarker != nil || controller.airportView != nil {
                Button { controller.clearGateMarker() } label: {
                    Label(controller.airportView.map { "Back · \($0.iata)" } ?? "Back",
                          systemImage: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12).padding(.top, 8)
            }
        }
    }

    /// Each tab shows the same draggable sheet over the shared map — the detent
    /// is shared state, so the height carries across tabs exactly as before.
    /// The sheet still slides away while a detail or add sheet is up, so two
    /// sheets are never stacked.
    private func tabSurface<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        // Built here rather than passed along, so the closure needn't escape.
        let built = content()
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
            BottomSheet(detent: $detent) { built.padding(.bottom, 56) }
                .offset(y: (detailFlight != nil || showAdd) ? 1500 : 0)
                .animation(.spring(duration: 0.45), value: detailFlight != nil || showAdd)
        }
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


