import SwiftUI
import SwiftData

/// Which cards My Trips is showing: the traveller's own journeys, or the
/// trip invites waiting behind the bell. The same stack pages either
/// (docs/superpowers/specs/2026-09-15-journey-stack-design.md, addendum).
enum TripsMode {
    case trips, invites
}

/// My Trips' cards, floating over the map. Folded: one journey at a time in
/// the stack — or, behind the bell, one invite at a time. Unfolded: a list of
/// every journey (or every invite) in a fixed frame the root reveals with a
/// mask. A flight stays here for 30 minutes after landing (arrival gate,
/// belt) before it lives only in Passport.
struct MyFlightsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Flight.scheduledDeparture) private var allFlights: [Flight]
    var onSelect: (Flight) -> Void
    var onAdd: () -> Void = {}
    /// A trip that just became the user's — an accepted invite is an import,
    /// and gets the same beat an add does: the row appears and the map draws
    /// the route on.
    var onImported: (Flight) -> Void = { _ in }
    /// A tap on an invited trip's card: the root opens its read-only preview.
    var onPreview: (FriendsStore.TripInviteItem, Flight) -> Void = { _, _ in }
    /// Trips that just became the user's, by id: once the route has drawn,
    /// the stack flips to the journey holding the topmost one.
    var landed: [UUID] = []
    /// Folded, the journey stack shows over the hidden list; unfolded, the
    /// list shows and scrolls (docs/superpowers/specs/2026-09-15-journey-stack-design.md).
    var folded = true
    /// The add moment is drawing a route. A trip that landed on another
    /// journey waits for the line to finish before the stack flips to it.
    var revealing = false
    /// Every card's height together (invites included, the room above short
    /// content not): how tall an unfolded list grows.
    var onContentHeight: (CGFloat) -> Void = { _ in }
    /// The journey the folded stack is on.
    var page: Binding<Int> = .constant(0)
    var motion: JourneyStackMotion? = nil
    var flipRequest: Int? = nil
    var onFlipRequestHandled: () -> Void = {}
    /// Height of everything above the stack in the folded overlay (the
    /// error, the invites and the gap under them); 0 when there is none.
    var onChromeHeight: (CGFloat) -> Void = { _ in }
    /// Room above short unfolded content (`MyTripsLayout.contentTopSpacer`).
    var topSpacer: CGFloat = 0
    /// A trip that landed on a journey the folded stack isn't on, once its
    /// route has drawn: the root flips the stack to that index.
    var onRevealJourney: (Int) -> Void = { _ in }
    /// The stack settled on another journey by its own motion; the map follows.
    var onStackSettled: (UUID) -> Void = { _ in }
    /// Nothing is in front of the trips (see `JourneyStack.hintsEnabled`); the
    /// folded stack may nudge when the screen goes quiet.
    var hintsEnabled = false
    /// Journeys, or the invites behind the bell. The fold is shared: swapping
    /// while unfolded shows the other list unfolded.
    var mode: TripsMode = .trips
    /// The invite the stack is on while it is showing invites.
    var invitePage: Binding<Int> = .constant(0)
    /// The invite stack landed on an invite — it has been on screen.
    var onInviteSettled: (String) -> Void = { _ in }

    @State private var friendsStore = FriendsStore.shared
    /// Landed ids `reveal` couldn't place yet — the save that produced them
    /// hasn't reached `allFlights` through the query. Retried on every
    /// change to the query until they resolve or drop out of the list.
    @State private var unresolvedLanded: Set<UUID> = []
    /// The journey a landed trip belongs to, held until its route has drawn.
    @State private var pendingRevealJourney: UUID?
    @State private var fallbackMotion = JourneyStackMotion()
    /// The mode whose stack is still dissolving on top of the new one.
    @State private var swapGhost: TripsMode?
    /// The folded overlay's own height, for its content's minimum.
    @State private var overlayViewport: CGFloat = 0
    @State private var ghostOpacity: Double = 1
    /// The ghost draws and nothing else: heights, hero frames and the rest
    /// handlers belong to the stack that has arrived.
    @State private var ghostMotion = JourneyStackMotion()
    /// The invites as they were a moment ago, and the one that was showing:
    /// answering the LAST invite empties the list in the very turn the mode
    /// swaps back, so the ghost would have nothing to fade and the trips
    /// would cut in. It fades this instead.
    @State private var heldInvites: [FriendsStore.TripInviteItem] = []
    @State private var heldInvitePage = 0
    @State private var listGeometry = FloatingListGeometry()
    /// How far below its scrolled place the list starts an unfold, when
    /// the scroll can't put the current card where the stack showed it.
    @State private var unfoldShift: CGFloat = 0
    /// When the last unfold started: a fold that interrupts it keeps the
    /// shift, so the list turns round from where it is instead of snapping.
    @State private var unfoldStartedAt = Date.distantPast
    /// When the last fold started, for the same turn-round the other way.
    @State private var foldStartedAt = Date.distantPast
    /// Roughly how long `ArcTheme.fold` takes to settle.
    private static let foldSettle: TimeInterval = 0.6

    /// Slack under the cards inside the list's frame, so a glass rim on the
    /// bottom edge is never clipped. The surface extends the frame by as much
    /// — one value, shared with every floating list (`MyTripsLayout.rim`).
    static let rim: CGFloat = MyTripsLayout.rim
    private static let bottomID = "trips-bottom"

    static let topID = "trips-top"

    /// The rows this list draws, in the order it draws them: active and
    /// recently-landed pinned above the upcoming-by-soonest timeline.
    static func listed(_ all: [Flight]) -> [Flight] {
        all
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

    static func journeys(_ all: [Flight]) -> [TripJourney] {
        TripJourney.group(listed(all), connections: ConnectionPlanner.detectConnections(from: all))
    }

    /// The row to bring into view for trips that just landed: the first of
    /// them in list order, or nothing when the list shows none of them (a
    /// hand-logged past trip has no row here, so nothing should jump).
    static func rowToReveal(_ landed: [Flight], among all: [Flight]) -> UUID? {
        rowToReveal(ids: Set(landed.map(\.id)), among: all)
    }

    static func rowToReveal(ids: Set<UUID>, among all: [Flight]) -> UUID? {
        listed(all).first { ids.contains($0.id) }?.id
    }

    var body: some View {
        let journeys = Self.journeys(Array(allFlights))
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                list(journeys)
                foldedOverlay(journeys)
            }
            // `-autoAcceptInvites`: press Accept on each seeded invite, a few
            // seconds apart, through the very handler the button uses — so
            // the accept moment can be recorded on a simulator nothing can
            // tap. Demo-only, like the seeds it acts on.
            .task {
                guard DemoSeed.isAutoAcceptRequested else { return }
                try? await Task.sleep(for: .seconds(4))
                for item in friendsStore.tripInvites {
                    accept(item)
                    try? await Task.sleep(for: .seconds(5))
                }
            }
            .onChange(of: landed) { _, ids in
                let ids = Set(ids)
                if !reveal(ids, journeys: journeys, proxy: proxy) { unresolvedLanded.formUnion(ids) }
            }
            .onChange(of: revealing) { _, isRevealing in
                if !isRevealing { landReveal(proxy) }
            }
            .onChange(of: folded) { _, nowFolded in
                if nowFolded {
                    // The list's card for the page glides down onto the
                    // stack as the mask closes, and the stack fades in riding
                    // with it, so the two copies cross in register. An unfold
                    // still rising keeps its shift and reverses from where it is.
                    foldStartedAt = .now
                    if Date.now.timeIntervalSince(unfoldStartedAt) > Self.foldSettle {
                        instantly { unfoldShift = reduceMotion ? 0 : foldShift(journeys) }
                    }
                } else if Date.now.timeIntervalSince(foldStartedAt) > Self.foldSettle {
                    alignListToPage(journeys, proxy: proxy)
                } else {
                    // A fold still closing turns round the same way.
                    unfoldStartedAt = .now
                }
            }
            // The stack stays on its journey when the list changes under it.
            .onChange(of: journeys.map(\.id)) { old, now in
                let followed = JourneyStackPaging.page(after: old, now: now, was: page.wrappedValue)
                if followed != page.wrappedValue { page.wrappedValue = followed }
            }
            .onChange(of: allFlights.map(\.id)) { _, _ in
                friendsStore.updateAirportOverlaps(with: Array(allFlights))
                friendsStore.reconcileTripInvites(with: Array(allFlights))
                // A save the query hadn't caught up with yet: try the same
                // reveal again now that `allFlights` moved.
                guard !unresolvedLanded.isEmpty else { return }
                if reveal(unresolvedLanded, journeys: journeys, proxy: proxy) {
                    unresolvedLanded.removeAll()
                } else {
                    // Drop ids that fell out of the list entirely (deleted,
                    // landed past the 30-minute window) — they'll never resolve.
                    let stillListed = Set(Self.listed(Array(allFlights)).map(\.id))
                    unresolvedLanded.formIntersection(stillListed)
                }
            }
        }
        .onAppear {
            friendsStore.updateAirportOverlaps(with: Array(allFlights))
            friendsStore.reconcileTripInvites(with: Array(allFlights))
        }
        // Invites for a journey the user already has answer themselves.
        .onChange(of: friendsStore.tripInvites.map(\.id), initial: true) { _, _ in
            friendsStore.reconcileTripInvites(with: Array(allFlights))
            // The last list that still had a card in it, for the ghost.
            if !friendsStore.tripInvites.isEmpty { heldInvites = friendsStore.tripInvites }
        }
        .onChange(of: invitePage.wrappedValue, initial: true) { _, page in
            heldInvitePage = page
        }
    }

    private var stackMotion: JourneyStackMotion { motion ?? fallbackMotion }

    private var fade: Animation? { reduceMotion ? nil : .easeOut(duration: 0.2) }

    // MARK: The list (unfolded)

    /// Every journey in a fixed frame that scrolls; shows, takes touches and
    /// speaks only while unfolded. Short content sits on the bottom edge.
    private func list(_ journeys: [TripJourney]) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    chromeItems
                    listRows(journeys)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onContentHeight(max(0, $0 - Self.rim)) }
                Color.clear.frame(height: 0).id(Self.bottomID)
            }
            .id(Self.topID)
            .coordinateSpace(.named(FloatingListRow.contentSpace))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listGeometry.content = $0 }
            .padding(.horizontal, MyTripsLayout.margin)
        }
        // Short content sits on the bottom edge through a content margin, not
        // a spacer inside the content: the refresh control sits just above
        // the content, so it shows inside the visible slice rather than at
        // the frame's top, masked away.
        .coordinateSpace(.named(FloatingListRow.viewportSpace))
        .contentMargins(.top, topSpacer, for: .scrollContent)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listGeometry.viewport = $0 }
        .scrollDisabled(folded)
        .scrollIndicators(.hidden)
        .refreshable {
            await FlightTracker.shared.burstUpdate(flights: Array(allFlights), modelContext: modelContext)
            // Pull-to-refresh is also "did anyone add a trip for me?"
            await friendsStore.refresh(force: true)
        }
        .animation(fade) { $0.opacity(folded ? 0 : 1) }
        .modifier(UnfoldRise(progress: folded ? 0 : 1, shift: unfoldShift))
        .allowsHitTesting(!folded)
        // `isEnabled`: an explicit `hidden: false` would outrank the hides
        // inside (the stack's parked neighbours).
        .accessibilityHidden(true, isEnabled: folded)
        .environment(\.heroReports, !folded)
    }

    /// The list's cards: every journey, or — behind the bell — every invite.
    /// Each carries the rim under it, so scrolling a card's bottom to the
    /// frame's puts the card itself where the folded stack shows it.
    @ViewBuilder
    private func listRows(_ journeys: [TripJourney]) -> some View {
        switch mode {
        case .trips:
            if journeys.isEmpty {
                emptyButton.padding(.bottom, Self.rim)
            } else {
                VStack(spacing: 10 - Self.rim) {
                    ForEach(Array(journeys.enumerated()), id: \.element.id) { index, journey in
                        JourneyCard(journey: journey,
                                    onSelect: { leg in select(leg, journeyAt: index) },
                                    onDelete: delete)
                            .modifier(FloatingListRow(key: journey.id.uuidString, geometry: listGeometry))
                    }
                }
            }
        case .invites:
            VStack(spacing: 10 - Self.rim) {
                ForEach(friendsStore.tripInvites) { item in
                    inviteCard(item)
                        .modifier(FloatingListRow(key: item.id, geometry: listGeometry))
                }
            }
        }
    }

    // MARK: The folded overlay

    /// The journey stack — or the invite stack the bell swaps in — or the
    /// empty state, sitting on the bottom edge. Shows only while folded.
    ///
    /// In a ScrollView that never scrolls or clips: a hide on a plain SwiftUI
    /// container here still left its buttons queryable (UI tests found the
    /// stack's rows twice once unfolded); a hide on a scroll view takes its
    /// whole content out, as it does for the list.
    private func foldedOverlay(_ journeys: [TripJourney]) -> some View {
        ScrollView {
            overlayContent(journeys)
                // At least the viewport's height, the cards on its bottom
                // edge: nothing for the scroll view to re-anchor. Left to
                // `defaultScrollAnchor` alone, the bell's swap (a height
                // change inside an animated update) threw the content to the
                // viewport's top, under the mask, for a few frames and slid
                // it back down (caught frame by frame). Taller content still
                // overflows upward, under the mask. The viewport is measured
                // rather than read with `containerRelativeFrame`, which loops
                // layout on iOS 27.
                .frame(minHeight: overlayViewport, alignment: .bottom)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { overlayViewport = $0 }
        .scrollDisabled(true)
        .scrollClipDisabled()
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        // Every role, not just alignment: invites that overflow the frame
        // leave the stack on the bottom edge (and the top invites under the
        // mask) rather than the stack pushed out of sight below it.
        .defaultScrollAnchor(.bottom)
        // Travels with the list's rise, so its card and the list's cross
        // in register instead of fading in two places.
        .modifier(UnfoldRise(progress: folded ? 0 : 1, shift: unfoldShift, overlay: true))
        .animation(fade) { $0.opacity(folded ? 1 : 0) }
        .allowsHitTesting(folded)
        .accessibilityHidden(true, isEnabled: !folded)
        .environment(\.heroReports, folded)
    }

    private func overlayContent(_ journeys: [TripJourney]) -> some View {
        VStack(spacing: 0) {
            if hasChrome {
                VStack(spacing: 10) { chromeItems }
                    .padding(.bottom, 10)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { publishChromeHeight($0) }
                    // Mid-swipe the stack's top edge moves; what sits on it moves too.
                    .modifier(RidesStackEdge(motion: stackMotion))
            }
            // The bell's swap: the stack leaving stays on top and dissolves
            // over the one arriving, in place, while the frame's height
            // springs from one card to the other
            // (`JourneyStackMotion.heightChange`). Nothing of the map is ever
            // seen between them.
            ZStack(alignment: .bottom) {
                stack(mode, journeys: journeys, motion: stackMotion, live: true)
                if let leaving = swapGhost {
                    stack(leaving, journeys: journeys, motion: ghostMotion, live: false)
                        .opacity(ghostOpacity)
                        // A picture of the card that was there, not a second
                        // copy of its buttons — and not a second row claiming
                        // the hero frame a glide would start from.
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .environment(\.heroReports, false)
                }
            }
            .onChange(of: mode) { old, _ in dissolve(from: old) }
        }
        .padding(.horizontal, MyTripsLayout.margin)
        .padding(.bottom, Self.rim)
        .onChange(of: hasChrome, initial: true) { _, has in
            if !has { publishChromeHeight(0) }
        }
    }

    /// The dissolve is quicker than the height's spring: the cards have
    /// swapped over by the time the frame finishes settling. Reduce Motion
    /// keeps it — a crossfade is the one thing it allows.
    private static let swapFade: Animation = .easeInOut(duration: 0.25)

    /// A transition can't do this: the stack arriving is one pixel tall until
    /// its card has been measured, so fading the two together showed the map
    /// through the gap for exactly one frame (caught frame by frame on the
    /// simulator). The one leaving is held on top instead and dissolved.
    private func dissolve(from old: TripsMode) {
        instantly {
            swapGhost = old
            ghostOpacity = 1
        }
        withAnimation(Self.swapFade, completionCriteria: .logicallyComplete) {
            ghostOpacity = 0
        } completion: {
            swapGhost = nil
        }
    }

    @ViewBuilder
    private func stack(_ mode: TripsMode, journeys: [TripJourney],
                       motion: JourneyStackMotion, live: Bool) -> some View {
        switch mode {
        case .trips: journeysStack(journeys, motion: motion, live: live)
        case .invites: invitesStack(motion: motion, live: live)
        }
    }

    @ViewBuilder
    private func journeysStack(_ journeys: [TripJourney], motion: JourneyStackMotion, live: Bool) -> some View {
        if journeys.isEmpty {
            emptyButton
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                    if live, motion.settledHeight != h { motion.settledHeight = h }
                }
        } else {
            JourneyStack(items: journeys, page: page, motion: motion,
                         flipRequest: live ? flipRequest : nil,
                         onFlipRequestHandled: live ? onFlipRequestHandled : {},
                         onSettled: live ? onStackSettled : { _ in },
                         // Unfolded, the overlay is still in the tree, only
                         // faded out: the list is what the user is reading.
                         hintsEnabled: live && hintsEnabled && folded,
                         label: "Journeys",
                         value: { journey, index, count in
                             "Journey \(index + 1) of \(count), \(Self.route(journey))"
                         }) { journey in
                JourneyCard(journey: journey, onSelect: onSelect, onDelete: delete)
            }
        }
    }

    /// The same pager, paging the invites: one at a time, flippable, with the
    /// dots, the heights and the hero frames a journey card gets. The ghost
    /// pages the invites as they were, so the one just answered fades out.
    private func invitesStack(motion: JourneyStackMotion, live: Bool) -> some View {
        let items = live ? friendsStore.tripInvites : heldInvites
        let page = live ? invitePage
            : .constant(min(max(heldInvitePage, 0), max(items.count - 1, 0)))
        return JourneyStack(items: items, page: page, motion: motion,
                     onSettled: live ? onInviteSettled : { _ in },
                     hintsEnabled: live && hintsEnabled && folded,
                     label: "Trip invitations",
                     value: { item, index, count in
                         "Invitation \(index + 1) of \(count), from \(item.sender.display_name)"
                     }) { item in
            inviteCard(item)
        }
    }

    private func inviteCard(_ item: FriendsStore.TripInviteItem) -> some View {
        TripInviteCard(item: item,
                       onOpen: { onPreview(item, $0) },
                       onAccept: { accept(item) },
                       onDecline: { friendsStore.decline(item) },
                       drawsBackground: false)
            .heroCopy(key: item.id, side: .list)
            .glassEffect(ArcTheme.tripGlass, in: .rect(cornerRadius: ArcTheme.cardCorner))
    }

    /// A height the swap causes springs with it; every other one lands flat.
    private func publishChromeHeight(_ h: CGFloat) {
        if let animation = stackMotion.heightChange {
            withAnimation(animation) { onChromeHeight(h) }
        } else {
            onChromeHeight(h)
        }
    }

    /// "Zurich to Rome": what VoiceOver adds to the stack's page count.
    static func route(_ journey: TripJourney) -> String {
        [journey.legs.first?.departureCity, journey.legs.last?.arrivalCity]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " to ")
    }

    private var hasChrome: Bool { chromeError != nil }

    /// A failed Accept sets `lastError` and leaves the card: the line belongs
    /// with the invites it is about, so it is the invite stack's chrome and
    /// is never seen over the journeys.
    private var chromeError: String? {
        guard mode == .invites, !friendsStore.tripInvites.isEmpty else { return nil }
        return friendsStore.lastError
    }

    /// What sits above the cards. In trips mode: nothing — the invites moved
    /// behind the bell.
    @ViewBuilder
    private var chromeItems: some View {
        if let error = chromeError {
            Text(error)
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .glassEffect(ArcTheme.tripGlass, in: .rect(cornerRadius: 16))
        }
    }

    private var emptyButton: some View {
        // The whole card takes the tap, not only the text and the blue block
        // inside it: glass is not a hit area of its own.
        Button(action: onAdd) { emptyState.contentShape(.rect) }
            .buttonStyle(.plain)
    }

    // MARK: Hand-offs

    /// The card the folded stack is showing, whichever kind it is: the key
    /// its row in the list carries.
    private func currentKey(_ journeys: [TripJourney]) -> String? {
        switch mode {
        case .trips:
            guard journeys.indices.contains(page.wrappedValue) else { return nil }
            return journeys[page.wrappedValue].id.uuidString
        case .invites:
            let invites = friendsStore.tripInvites
            guard invites.indices.contains(invitePage.wrappedValue) else { return nil }
            return invites[invitePage.wrappedValue].id
        }
    }

    /// Unfolding: scroll the still-hidden list, before the mask moves, so the
    /// current card sits where the stack shows it. Where the scroll
    /// can't reach that far (too little above it, or below it), the list
    /// starts shifted by the rest and rises into place with the fold.
    private func alignListToPage(_ journeys: [TripJourney], proxy: ScrollViewProxy) {
        guard let id = currentKey(journeys) else { return }
        guard let placement = listGeometry.unfoldPlacement(for: id, topSpacer: topSpacer) else {
            instantly { proxy.scrollTo(id, anchor: .bottom); unfoldShift = 0 }
            return
        }
        unfoldStartedAt = .now
        instantly {
            switch placement.scroll {
            case .top: proxy.scrollTo(Self.topID, anchor: .top)
            case .bottom: proxy.scrollTo(Self.bottomID, anchor: .bottom)
            case .card: proxy.scrollTo(id, anchor: .bottom)
            }
            unfoldShift = reduceMotion ? 0 : placement.shift
        }
    }

    /// How far the list must move for its card of the current page to land
    /// where the stack shows it, as the fold closes.
    private func foldShift(_ journeys: [TripJourney]) -> CGFloat {
        guard let id = currentKey(journeys) else { return 0 }
        return listGeometry.foldShift(for: id)
    }

    /// A card opened from the unfolded list becomes the stack's page, so
    /// Show Less folds onto it.
    private func select(_ leg: Flight, journeyAt index: Int) {
        if page.wrappedValue != index { page.wrappedValue = index }
        onSelect(leg)
    }

    /// Notes the journey holding the topmost of `ids`, when the query has
    /// already caught up with the save that produced them. False means the
    /// caller should retry once `allFlights` changes again.
    private func reveal(_ ids: Set<UUID>, journeys: [TripJourney], proxy: ScrollViewProxy) -> Bool {
        guard let row = Self.rowToReveal(ids: ids, among: Array(allFlights)),
              let journey = journeys.first(where: { $0.legs.contains { $0.id == row } })
        else { return false }
        pendingRevealJourney = journey.id
        // Nothing to draw, so nothing to wait for — but a turn later, once
        // the stack has taken in the list change that brought the trip.
        if !revealing {
            DispatchQueue.main.async { if !revealing { landReveal(proxy) } }
        }
        return true
    }

    /// The route has drawn: a folded stack flips to the landed journey; an
    /// unfolded list scrolls to it and makes it the page.
    private func landReveal(_ proxy: ScrollViewProxy) {
        guard let target = pendingRevealJourney else { return }
        pendingRevealJourney = nil
        let journeys = Self.journeys(Array(allFlights))
        guard let index = journeys.firstIndex(where: { $0.id == target }) else { return }
        if folded {
            if index != page.wrappedValue { onRevealJourney(index) }
        } else {
            if page.wrappedValue != index { page.wrappedValue = index }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                if index == 0 {
                    proxy.scrollTo(Self.topID, anchor: .top)
                } else {
                    proxy.scrollTo(target.uuidString, anchor: .top)
                }
            }
        }
    }

    private func instantly(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }

    private func accept(_ item: FriendsStore.TripInviteItem) {
        Task {
            // Only a trip that really materialised gets the moment — a failed
            // save leaves the card and its error, with nothing to draw.
            if let imported = await friendsStore.accept(item, into: modelContext) {
                onImported(imported)
            }
        }
    }

    private func delete(_ flight: Flight) {
        Task { await Flight.delete(flight, from: modelContext) }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "airplane")
                Image(systemName: "tram.fill")
                Image(systemName: "ferry.fill")
            }
            .font(.title3)
            .foregroundStyle(ArcTheme.brand)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Your next journey\nstarts here.")
                    .font(.title.bold())
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Bring your flights, trains and ferries together. One place for the journey ahead.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(allFlights.isEmpty ? "Add your first trip" : "Add your next trip").font(.headline)
                Spacer()
                Image(systemName: "arrow.up.right").font(.headline)
            }
            .foregroundStyle(.white)
            .padding(16)
            .background(ArcTheme.brand, in: RoundedRectangle(cornerRadius: 16))
            Text("Search a route, paste a booking or scan a boarding pass.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(ArcTheme.tripGlass, in: .rect(cornerRadius: ArcTheme.cardCorner))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens trip search, booking import and boarding pass scanning")
    }
}
