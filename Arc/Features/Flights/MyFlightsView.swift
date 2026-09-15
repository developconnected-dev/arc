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
    /// Trips that just became the user's, by id: the stack brings the
    /// journey holding the topmost one into view.
    var landed: [UUID] = []
    /// Folded, only the first block shows and nothing scrolls.
    var folded = true
    /// Whether the journeys after the first are built at all: from the start
    /// of an unfold until a fold has finished closing over them.
    var showsRest = false
    /// The add moment is drawing a route. A trip that landed below the fold
    /// waits for the line to finish before the stack unfolds over the map.
    var revealing = false
    var onFoldedHeight: (CGFloat) -> Void = { _ in }
    /// Asks the root to unfold, then runs the closure once the stack is open.
    var onUnfold: (@escaping () -> Void) -> Void = { $0() }

    @State private var friendsStore = FriendsStore.shared
    @State private var pendingJourney: UUID?
    /// Landed ids `reveal` couldn't place yet — the save that produced them
    /// hasn't reached `allFlights` through the query. Retried on every
    /// change to the query until they resolve or drop out of the list.
    @State private var unresolvedLanded: Set<UUID> = []

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
            ScrollView {
                VStack(spacing: 10) {
                    foldedBlock(journeys.first)
                        .id(Self.topID)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onFoldedHeight($0) }
                    if showsRest {
                        ForEach(journeys.dropFirst()) { journey in
                            JourneyCard(journey: journey, onSelect: onSelect, onDelete: delete)
                                .id(journey.id)
                        }
                    }
                }
                .padding(.horizontal, MyTripsLayout.margin)
                .padding(.bottom, 12)
            }
            .scrollDisabled(folded)
            .scrollIndicators(.hidden)
            .refreshable {
                await FlightTracker.shared.burstUpdate(flights: Array(allFlights), modelContext: modelContext)
                // Pull-to-refresh is also "did anyone add a trip for me?"
                await friendsStore.refresh(force: true)
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
                if !isRevealing { unfoldToPending(proxy) }
            }
            // Folding scrolls home in the same spring the stack closes with,
            // so the first block is what the fold settles on.
            .onChange(of: folded) { _, nowFolded in
                guard nowFolded else { return }
                withAnimation(reduceMotion ? nil : ArcTheme.fold) { proxy.scrollTo(Self.topID, anchor: .top) }
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

    /// Scrolls to the journey holding one of `ids`' topmost row, when the
    /// query has already caught up with the save that produced them. False
    /// means the caller should retry once `allFlights` changes again.
    private func reveal(_ ids: Set<UUID>, journeys: [TripJourney], proxy: ScrollViewProxy) -> Bool {
        guard let row = Self.rowToReveal(ids: ids, among: Array(allFlights)),
              let index = journeys.firstIndex(where: { $0.legs.contains { $0.id == row } })
        else { return false }
        if index == 0 {
            // The folded card already shows it — but an unfolded stack may
            // have scrolled past it, so bring it back to the top.
            if !folded {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                    proxy.scrollTo(Self.topID, anchor: .top)
                }
            }
        } else {
            pendingJourney = journeys[index].id
            if !revealing { unfoldToPending(proxy) }
        }
        return true
    }

    /// Everything a folded stack shows: invites (they need an answer) and the
    /// next journey, or the empty state.
    @ViewBuilder
    private func foldedBlock(_ next: TripJourney?) -> some View {
        VStack(spacing: 10) {
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
            if let next {
                JourneyCard(journey: next, showsBrief: true, onSelect: onSelect, onDelete: delete)
            } else {
                Button(action: onAdd) { emptyState }
                    .buttonStyle(.plain)
            }
        }
    }

    private func unfoldToPending(_ proxy: ScrollViewProxy) {
        guard let target = pendingJourney else { return }
        pendingJourney = nil
        onUnfold {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                proxy.scrollTo(target, anchor: .top)
            }
        }
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
