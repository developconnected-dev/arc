import SwiftUI
import SwiftData

/// My Trips' cards, floating over the map: trip invites and the next journey
/// first (all a folded stack shows), then every later journey. The root
/// places, masks and fades this view; it only lays the cards out. A flight
/// stays here for 30 minutes after landing (arrival gate, belt) before it
/// lives only in Passport.
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

    @State private var friendsStore = FriendsStore.shared
    /// Landed ids `reveal` couldn't place yet — the save that produced them
    /// hasn't reached `allFlights` through the query. Retried on every
    /// change to the query until they resolve or drop out of the list.
    @State private var unresolvedLanded: Set<UUID> = []
    /// The journey a landed trip belongs to, held until its route has drawn.
    @State private var pendingRevealJourney: UUID?
    @State private var fallbackMotion = JourneyStackMotion()
    @State private var listGeometry = ListGeometry()
    /// How far below its scrolled place the list starts an unfold, when
    /// the scroll can't put the current card where the stack showed it.
    @State private var unfoldShift: CGFloat = 0

    /// Slack under the cards inside the list's frame, so a glass rim on the
    /// bottom edge is never clipped. The root extends the frame by as much.
    static let rim: CGFloat = 6
    private static let bottomID = "trips-bottom"
    nonisolated private static let contentSpace = "trips-list-content"

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
                    // Nothing to scroll: the stack fades in on its page while
                    // the mask closes over the list.
                    instantly { unfoldShift = 0 }
                } else {
                    alignListToPage(journeys, proxy: proxy)
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
        .onChange(of: friendsStore.tripInvites.map(\.id)) { _, _ in
            friendsStore.reconcileTripInvites(with: Array(allFlights))
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
                Color.clear.frame(height: topSpacer)
                VStack(spacing: 10) {
                    chromeItems
                    if journeys.isEmpty {
                        emptyButton.padding(.bottom, Self.rim)
                    } else {
                        // Each card carries the rim under it, so scrolling a
                        // card's bottom to the frame's puts the card itself
                        // where the folded stack shows it.
                        VStack(spacing: 10 - Self.rim) {
                            ForEach(Array(journeys.enumerated()), id: \.element.id) { index, journey in
                                JourneyCard(journey: journey,
                                            onSelect: { leg in select(leg, journeyAt: index) },
                                            onDelete: delete)
                                    .padding(.bottom, Self.rim)
                                    .id(journey.id)
                                    .onGeometryChange(for: CGFloat.self) {
                                        $0.frame(in: .named(Self.contentSpace)).maxY
                                    } action: { listGeometry.cardBottoms[journey.id] = $0 }
                            }
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onContentHeight(max(0, $0 - Self.rim)) }
                Color.clear.frame(height: 0).id(Self.bottomID)
            }
            .id(Self.topID)
            .coordinateSpace(.named(Self.contentSpace))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listGeometry.content = $0 }
            .padding(.horizontal, MyTripsLayout.margin)
        }
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
        .accessibilityHidden(folded)
        .environment(\.heroReports, !folded)
    }

    // MARK: The folded overlay

    /// Invites (they need an answer) over the journey stack, or the empty
    /// state, sitting on the bottom edge. Shows only while folded.
    private func foldedOverlay(_ journeys: [TripJourney]) -> some View {
        VStack(spacing: 0) {
            if hasChrome {
                VStack(spacing: 10) { chromeItems }
                    .padding(.bottom, 10)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onChromeHeight($0) }
                    // Mid-swipe the stack's top edge moves; what sits on it moves too.
                    .modifier(RidesStackEdge(motion: stackMotion))
            }
            if journeys.isEmpty {
                emptyButton
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                        if stackMotion.settledHeight != h { stackMotion.settledHeight = h }
                    }
            } else {
                JourneyStack(journeys: journeys, page: page, motion: stackMotion,
                             flipRequest: flipRequest, onFlipRequestHandled: onFlipRequestHandled,
                             onSelect: onSelect, onDelete: delete)
            }
        }
        .padding(.horizontal, MyTripsLayout.margin)
        .padding(.bottom, Self.rim)
        .onChange(of: hasChrome, initial: true) { _, has in
            if !has { onChromeHeight(0) }
        }
        .animation(fade) { $0.opacity(folded ? 1 : 0) }
        .allowsHitTesting(folded)
        .accessibilityHidden(!folded)
        .environment(\.heroReports, folded)
    }

    private var hasChrome: Bool {
        !friendsStore.tripInvites.isEmpty
    }

    /// What sits above the journeys: a failed Accept's error and the invites.
    @ViewBuilder
    private var chromeItems: some View {
        // A failed Accept sets lastError and leaves the card.
        if let error = friendsStore.lastError, !friendsStore.tripInvites.isEmpty {
            Text(error)
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .glassEffect(ArcTheme.tripGlass, in: .rect(cornerRadius: 16))
        }
        ForEach(friendsStore.tripInvites) { item in
            TripInviteCard(item: item,
                           onOpen: { onPreview(item, $0) },
                           onAccept: { accept(item) },
                           onDecline: { friendsStore.decline(item) },
                           drawsBackground: false)
                .heroCopy(key: item.id, side: .list)
                .glassEffect(ArcTheme.tripGlass, in: .rect(cornerRadius: ArcTheme.cardCorner))
        }
    }

    private var emptyButton: some View {
        Button(action: onAdd) { emptyState }
            .buttonStyle(.plain)
    }

    // MARK: Hand-offs

    /// Unfolding: scroll the still-hidden list, before the mask moves, so the
    /// current journey's card sits where the stack shows it. Where the scroll
    /// can't reach that far (too little above it, or below it), the list
    /// starts shifted by the rest and rises into place with the fold.
    private func alignListToPage(_ journeys: [TripJourney], proxy: ScrollViewProxy) {
        let index = page.wrappedValue
        guard journeys.indices.contains(index) else { return }
        let id = journeys[index].id
        let g = listGeometry
        guard let bottom = g.cardBottoms[id], g.viewport > 0 else {
            instantly { proxy.scrollTo(id, anchor: .bottom); unfoldShift = 0 }
            return
        }
        let desired = bottom - g.viewport
        let reach = max(0, g.content - g.viewport)
        let actual = min(max(desired, 0), reach)
        instantly {
            if desired <= 0 {
                proxy.scrollTo(Self.topID, anchor: .top)
            } else if desired >= reach {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            } else {
                proxy.scrollTo(id, anchor: .bottom)
            }
            unfoldShift = reduceMotion ? 0 : actual - desired
        }
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
                    proxy.scrollTo(target, anchor: .top)
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

/// Where the unfolded list's cards sit in its content, for the unfold's
/// scroll. Written by layout, read by one action: not observed, so no
/// measurement re-evaluates the view.
@MainActor
private final class ListGeometry {
    /// Each journey card's bottom (rim included), in content coordinates.
    var cardBottoms: [UUID: CGFloat] = [:]
    var content: CGFloat = 0
    var viewport: CGFloat = 0
}

/// The list's rise on unfold when its scroll can't hold the current card in
/// place: `shift` below at the fold's start, home when it ends, on the same
/// spring as the mask.
private struct UnfoldRise: ViewModifier, Animatable {
    var progress: CGFloat
    let shift: CGFloat
    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        content.offset(y: shift * (1 - min(max(progress, 0), 1)))
    }
}
