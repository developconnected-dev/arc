import SwiftUI

/// Which cards Friends is showing: friends' flights, or the friend requests
/// waiting behind the bell. The same stack pages either
/// (docs/superpowers/specs/2026-09-16-friends-floating-design.md).
enum FriendsMode {
    case flights, requests
}

/// One open friend request: a card of its own behind Friends' bell.
struct FriendRequest: Identifiable {
    let friendship: ArcSupabase.Friendship
    let user: ArcSupabase.ArcUser
    var id: String { friendship.id }
}

extension FriendsStore {
    /// The open friend requests, in the order they arrived: what the bell
    /// swaps the stack to.
    var requests: [FriendRequest] {
        pending.map { FriendRequest(friendship: $0.friendship, user: $0.user) }
    }
}

/// Friends' cards, floating over the map — `MyFlightsView`'s shape, with
/// friends' flights in it. Folded: one flight at a time in the stack (the
/// ones in the air first, then the next to leave; a flight several friends
/// share is one card), or — behind the bell — one friend request at a time.
/// Unfolded: every flight the filter admits, then the Past Flights row, in a
/// fixed frame the surface reveals with a mask.
struct FriendsFloatingList: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What the filter admits, and the filter itself (`FriendsListView`).
    let feed: FriendsFeed
    /// A friend's flight was tapped: the root opens it in the panel, gliding
    /// from the card.
    var onSelect: (FriendFlightGroup) -> Void
    /// Folded, the stack shows over the hidden list; unfolded, the list shows
    /// and scrolls.
    var folded = true
    /// Every card's height together (the room above short content not): how
    /// tall an unfolded list grows.
    var onContentHeight: (CGFloat) -> Void = { _ in }
    /// The flight the folded stack is on.
    var page: Binding<Int> = .constant(0)
    var motion: JourneyStackMotion? = nil
    var flipRequest: Int? = nil
    var onFlipRequestHandled: () -> Void = {}
    /// Height of everything above the stack in the folded overlay (the error
    /// and the gap under it); 0 when there is none.
    var onChromeHeight: (CGFloat) -> Void = { _ in }
    /// Room above short unfolded content (`MyTripsLayout.contentTopSpacer`).
    var topSpacer: CGFloat = 0
    /// The stack settled on another flight by its own motion (by the group's
    /// id); the map follows.
    var onFlightSettled: (String) -> Void = { _ in }
    /// Nothing is in front of the cards (see `JourneyStack.hintsEnabled`).
    var hintsEnabled = false
    /// Flights, or the requests behind the bell. The fold is shared.
    var mode: FriendsMode = .flights
    /// The request the stack is on while it is showing requests.
    var requestPage: Binding<Int> = .constant(0)
    /// The request stack landed on a request — it has been on screen.
    var onRequestSettled: (String) -> Void = { _ in }

    @State private var store = FriendsStore.shared
    @State private var fallbackMotion = JourneyStackMotion()
    /// The mode whose stack is still dissolving on top of the new one.
    @State private var swapGhost: FriendsMode?
    /// The folded overlay's own height, for its content's minimum.
    @State private var overlayViewport: CGFloat = 0
    @State private var ghostOpacity: Double = 1
    /// The ghost draws and nothing else (see `MyFlightsView.ghostMotion`).
    @State private var ghostMotion = JourneyStackMotion()
    /// The requests as they were a moment ago, and the one that was showing:
    /// answering the LAST one empties the list in the very turn the mode
    /// swaps back, so the ghost fades this instead.
    @State private var heldRequests: [FriendRequest] = []
    @State private var heldRequestPage = 0
    @State private var listGeometry = FloatingListGeometry()
    /// The unfold's rise and its turn-round (see `MyFlightsView.unfoldShift`).
    @State private var unfoldShift: CGFloat = 0
    @State private var unfoldStartedAt = Date.distantPast
    @State private var foldStartedAt = Date.distantPast
    @State private var showPastFlights = false
    /// Roughly how long `ArcTheme.fold` takes to settle.
    private static let foldSettle: TimeInterval = 0.6

    private static let rim: CGFloat = MyTripsLayout.rim
    private static let topID = "friends-top"
    private static let bottomID = "friends-bottom"

    var body: some View {
        let flights = feed.flights
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                list(flights)
                foldedOverlay(flights)
            }
            .onChange(of: folded) { _, nowFolded in
                // The same hand-off as My Trips: the list's card glides onto
                // the stack as the mask closes, and an interrupted fold turns
                // round from where it is.
                if nowFolded {
                    foldStartedAt = .now
                    if Date.now.timeIntervalSince(unfoldStartedAt) > Self.foldSettle {
                        instantly { unfoldShift = reduceMotion ? 0 : foldShift(flights) }
                    }
                } else if Date.now.timeIntervalSince(foldStartedAt) > Self.foldSettle {
                    alignListToPage(flights, proxy: proxy)
                } else {
                    unfoldStartedAt = .now
                }
            }
            // The stack stays on its flight when the feed or the filter
            // changes under it.
            .onChange(of: flights.map(\.id)) { old, now in
                let followed = JourneyStackPaging.page(after: old, now: now, was: page.wrappedValue)
                if followed != page.wrappedValue { page.wrappedValue = followed }
            }
        }
        .onChange(of: store.requests.map(\.id), initial: true) { _, _ in
            // The last list that still had a card in it, for the ghost.
            let requests = store.requests
            if !requests.isEmpty { heldRequests = requests }
        }
        .onChange(of: requestPage.wrappedValue, initial: true) { _, page in
            heldRequestPage = page
        }
    }

    private var stackMotion: JourneyStackMotion { motion ?? fallbackMotion }

    private var fade: Animation? { reduceMotion ? nil : .easeOut(duration: 0.2) }

    // MARK: The list (unfolded)

    /// Every flight the filter admits, then Past Flights, in a fixed frame
    /// that scrolls; shows, takes touches and speaks only while unfolded.
    private func list(_ flights: [FriendFlightGroup]) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    chromeItems
                    listRows(flights)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onContentHeight(max(0, $0 - Self.rim)) }
                Color.clear.frame(height: 0).id(Self.bottomID)
            }
            .id(Self.topID)
            .coordinateSpace(.named(FloatingListRow.contentSpace))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listGeometry.content = $0 }
            .padding(.horizontal, MyTripsLayout.margin)
        }
        .coordinateSpace(.named(FloatingListRow.viewportSpace))
        .contentMargins(.top, topSpacer, for: .scrollContent)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listGeometry.viewport = $0 }
        .scrollDisabled(folded)
        .scrollIndicators(.hidden)
        // A deliberate pull means "tell me what is true NOW". Re-read the
        // rows, and have the server re-check the legs close enough for the
        // answer to have moved — bounded, because a pull with twenty friends
        // in the feed must not become twenty calls.
        .refreshable { await store.refreshLiveVisible() }
        .animation(fade) { $0.opacity(folded ? 0 : 1) }
        .modifier(UnfoldRise(progress: folded ? 0 : 1, shift: unfoldShift))
        .allowsHitTesting(!folded)
        .accessibilityHidden(true, isEnabled: folded)
        .environment(\.heroReports, !folded)
    }

    /// The list's cards: every flight and the past ones under their row, or
    /// — behind the bell — every request. Each carries the rim under it.
    @ViewBuilder
    private func listRows(_ flights: [FriendFlightGroup]) -> some View {
        switch mode {
        case .flights:
            VStack(spacing: 10 - Self.rim) {
                if flights.isEmpty {
                    emptyCard.padding(.bottom, Self.rim)
                } else {
                    ForEach(Array(flights.enumerated()), id: \.element.id) { index, group in
                        flightCard(group, onTap: { select(group, at: index) })
                            .modifier(FloatingListRow(key: group.id, geometry: listGeometry))
                    }
                }
                if !feed.past.isEmpty {
                    pastSection
                }
            }
            // Filter changes fade the cards instead of snapping.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: flights.map(\.id))
        case .requests:
            VStack(spacing: 10 - Self.rim) {
                ForEach(store.requests) { request in
                    requestCard(request)
                        .modifier(FloatingListRow(key: request.id, geometry: listGeometry))
                }
            }
        }
    }

    /// Past Flights live only here, at the end of the list, under a row that
    /// opens them — the row sits on the bottom edge until it does.
    private var pastSection: some View {
        let past = feed.past
        return VStack(spacing: 10 - Self.rim) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { showPastFlights.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("Past Flights")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text("\(past.count)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showPastFlights ? 180 : 0))
                }
                .padding(.horizontal, 20)
                .frame(height: 48)
                .contentShape(.rect)
                .glassEffect(ArcTheme.tripGlass, in: .rect(cornerRadius: ArcTheme.cardCorner))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("friends-past-toggle")
            .accessibilityValue(showPastFlights ? "Expanded" : "Collapsed")
            .modifier(ShownCopyOnly())
            .padding(.bottom, Self.rim)

            if showPastFlights {
                ForEach(past) { group in
                    flightCard(group, dimmed: true, onTap: { onSelect(group) })
                        .padding(.bottom, Self.rim)
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: The folded overlay

    /// The flights stack — or the requests stack the bell swaps in — or the
    /// empty card, sitting on the bottom edge. Shows only while folded. In a
    /// scroll view that never scrolls, for the reason `MyFlightsView` gives.
    private func foldedOverlay(_ flights: [FriendFlightGroup]) -> some View {
        ScrollView {
            overlayContent(flights)
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
        .defaultScrollAnchor(.bottom)
        .modifier(UnfoldRise(progress: folded ? 0 : 1, shift: unfoldShift, overlay: true))
        .animation(fade) { $0.opacity(folded ? 1 : 0) }
        .allowsHitTesting(folded)
        .accessibilityHidden(true, isEnabled: !folded)
        .environment(\.heroReports, folded)
    }

    private func overlayContent(_ flights: [FriendFlightGroup]) -> some View {
        VStack(spacing: 0) {
            if hasChrome {
                VStack(spacing: 10) { chromeItems }
                    .padding(.bottom, 10)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { publishChromeHeight($0) }
                    // Mid-swipe the stack's top edge moves; what sits on it moves too.
                    .modifier(RidesStackEdge(motion: stackMotion))
            }
            // The bell's swap: the stack leaving dissolves over the one
            // arriving, in place (see `MyFlightsView.dissolve`).
            ZStack(alignment: .bottom) {
                stack(mode, flights: flights, motion: stackMotion, live: true)
                if let leaving = swapGhost {
                    stack(leaving, flights: flights, motion: ghostMotion, live: false)
                        .opacity(ghostOpacity)
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

    /// Quicker than the height's spring; Reduce Motion keeps it — a
    /// crossfade is the one thing it allows.
    private static let swapFade: Animation = .easeInOut(duration: 0.25)

    private func dissolve(from old: FriendsMode) {
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
    private func stack(_ mode: FriendsMode, flights: [FriendFlightGroup],
                       motion: JourneyStackMotion, live: Bool) -> some View {
        switch mode {
        case .flights: flightsStack(flights, motion: motion, live: live)
        case .requests: requestsStack(motion: motion, live: live)
        }
    }

    @ViewBuilder
    private func flightsStack(_ flights: [FriendFlightGroup], motion: JourneyStackMotion, live: Bool) -> some View {
        if flights.isEmpty {
            // A single glass card where the stack would be.
            emptyCard
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                    if live, motion.settledHeight != h { motion.settledHeight = h }
                }
        } else {
            JourneyStack(items: flights, page: page, motion: motion,
                         flipRequest: live ? flipRequest : nil,
                         onFlipRequestHandled: live ? onFlipRequestHandled : {},
                         onSettled: live ? onFlightSettled : { _ in },
                         hintsEnabled: live && hintsEnabled && folded,
                         label: "Friends' flights",
                         identifier: "friends-stack",
                         value: { group, index, count in
                             "Flight \(index + 1) of \(count), \(Self.route(group))"
                         }) { group in
                flightCard(group, onTap: { onSelect(group) })
            }
        }
    }

    /// The same pager, paging the requests. The ghost pages them as they
    /// were, so the one just answered fades out.
    private func requestsStack(motion: JourneyStackMotion, live: Bool) -> some View {
        let items = live ? store.requests : heldRequests
        let page = live ? requestPage
            : .constant(min(max(heldRequestPage, 0), max(items.count - 1, 0)))
        return JourneyStack(items: items, page: page, motion: motion,
                            onSettled: live ? onRequestSettled : { _ in },
                            hintsEnabled: live && hintsEnabled && folded,
                            label: "Friend requests",
                            identifier: "friends-stack",
                            value: { request, index, count in
                                "Request \(index + 1) of \(count), from \(request.user.display_name)"
                            }) { request in
            requestCard(request)
        }
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
    static func route(_ group: FriendFlightGroup) -> String {
        let flight = group.representative.flight
        let from = flight.departure_city.isEmpty ? flight.departure_iata : flight.departure_city
        let to = flight.arrival_city.isEmpty ? flight.arrival_iata : flight.arrival_city
        return [from, to].filter { !$0.isEmpty }.joined(separator: " to ")
    }

    private var hasChrome: Bool { store.lastError != nil }

    /// What sits above the cards: the error line, when the last load or the
    /// last answer to a request failed.
    @ViewBuilder
    private var chromeItems: some View {
        if let error = store.lastError {
            Text(error)
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .glassEffect(ArcTheme.tripGlass, in: .rect(cornerRadius: 16))
        }
    }

    // MARK: Cards

    /// A friend's flight on its own glass: the card the detail opens from and
    /// closes back into.
    private func flightCard(_ group: FriendFlightGroup, dimmed: Bool = false,
                            onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            FriendFlightRow(group: group)
                .opacity(dimmed ? 0.7 : 1)
                .heroCopy(key: group.id, side: .list)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("friend-trip-\(group.representative.id)")
        .modifier(ShownCopyOnly())
        .glassEffect(ArcTheme.tripGlass, in: .rect(cornerRadius: ArcTheme.cardCorner))
    }

    private func requestCard(_ request: FriendRequest) -> some View {
        HStack(spacing: 12) {
            FriendAvatar(name: request.user.display_name, size: 40, avatarURL: request.user.avatar_url)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.user.display_name).font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text("Wants to be friends").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            // A request card with only Accept was a card that could never
            // leave: an unwanted request sat pinned above the feed for ever.
            Button { decline(request) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Color.primary.opacity(0.08), in: Circle())
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Decline")
            .accessibilityIdentifier("friend-request-decline")
            Button { accept(request) } label: {
                Text("Accept")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 32)
                    .background(ArcTheme.action, in: Capsule())
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("friend-request-accept")
        }
        // The stack's page dots sit on the card's trailing edge.
        .padding(.vertical, 16).padding(.leading, 16).padding(.trailing, 24)
        .glassEffect(ArcTheme.tripGlass, in: .rect(cornerRadius: ArcTheme.cardCorner))
        .modifier(ShownCopyOnly())
    }

    /// "No friends yet", "No flights right now", "No flights in this filter",
    /// or — before the first load has answered — a quiet spinner: one glass
    /// card where the stack would be. Says nothing false while loading.
    @ViewBuilder
    private var emptyCard: some View {
        if store.friends.isEmpty && !store.isLoading && store.hasLoadedOnce {
            // The whole card takes the tap: glass is not a hit area of its own.
            Button(action: feed.onAdd) {
                emptyContent(icon: "person.2.wave.2", title: "No friends yet",
                             detail: "Share an invite link — connecting takes one tap.",
                             action: "Tap to invite")
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .glassEffect(ArcTheme.tripGlass, in: .rect(cornerRadius: ArcTheme.cardCorner))
            .accessibilityIdentifier("friends-empty")
            .modifier(ShownCopyOnly())
        } else if !store.isLoading && store.hasLoadedOnce {
            emptyContent(icon: "airplane.circle",
                         title: feed.filter.wrappedValue == .all ? "No flights right now" : "No flights in this filter",
                         detail: nil, action: nil)
                .glassEffect(ArcTheme.tripGlass, in: .rect(cornerRadius: ArcTheme.cardCorner))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("friends-empty")
                .modifier(ShownCopyOnly())
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
                .frame(height: 96)
                .glassEffect(ArcTheme.tripGlass, in: .rect(cornerRadius: ArcTheme.cardCorner))
        }
    }

    private func emptyContent(icon: String, title: String, detail: String?, action: String?) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 36)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.secondary)
            if let detail {
                Text(detail).font(.system(size: 13)).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            if let action {
                Text(action).font(.system(size: 13, weight: .semibold)).foregroundStyle(ArcTheme.action)
            }
        }
        .padding(.vertical, 22).padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
    }

    // MARK: Hand-offs

    /// The card the folded stack is showing, whichever kind it is: the key
    /// its row in the list carries.
    private func currentKey(_ flights: [FriendFlightGroup]) -> String? {
        switch mode {
        case .flights:
            guard flights.indices.contains(page.wrappedValue) else { return nil }
            return flights[page.wrappedValue].id
        case .requests:
            let requests = store.requests
            guard requests.indices.contains(requestPage.wrappedValue) else { return nil }
            return requests[requestPage.wrappedValue].id
        }
    }

    /// Unfolding: scroll the still-hidden list so the current card sits
    /// where the stack shows it, or start it shifted by what the scroll
    /// can't reach (`FloatingListGeometry.unfoldPlacement`).
    private func alignListToPage(_ flights: [FriendFlightGroup], proxy: ScrollViewProxy) {
        guard let id = currentKey(flights) else { return }
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

    private func foldShift(_ flights: [FriendFlightGroup]) -> CGFloat {
        guard let id = currentKey(flights) else { return 0 }
        return listGeometry.foldShift(for: id)
    }

    /// A card opened from the unfolded list becomes the stack's page, so
    /// Show Less folds onto it.
    private func select(_ group: FriendFlightGroup, at index: Int) {
        if page.wrappedValue != index { page.wrappedValue = index }
        onSelect(group)
    }

    private func instantly(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }

    private func accept(_ request: FriendRequest) {
        if DemoSeed.isFriendRequestsRequested { answerDemo(request); return }
        Task {
            // On success the refresh clears the card; on failure the card
            // stays AND the error line says why — a swallowed throw here left
            // a tap indistinguishable from no tap.
            do {
                try await ArcSupabase.shared.acceptFriendRequest(friendshipId: request.friendship.id)
                await store.refresh(force: true)
            } catch {
                store.lastError = "Couldn't accept the request — check your connection and try again."
            }
        }
    }

    private func decline(_ request: FriendRequest) {
        if DemoSeed.isFriendRequestsRequested { answerDemo(request); return }
        Task {
            do {
                try await ArcSupabase.shared.removeFriendship(with: request.user.id)
                await store.refresh(force: true)
            } catch {
                store.lastError = "Couldn't decline the request — check your connection and try again."
            }
        }
    }
}

extension FriendsFloatingList {
    /// `-seedFriendRequestsDemo`: there is no server to answer, so the card
    /// simply goes, as a successful refresh would take it.
    fileprivate func answerDemo(_ request: FriendRequest) {
        store.pending.removeAll { $0.friendship.id == request.id }
    }
}

/// The list and the stack hold the same cards; only the copy on screen
/// (`heroReports`) may be found. Set on the card itself: inside the sheet, a
/// hide on the overlay's scroll view left its buttons queryable by
/// identifier, where a hide on the element never does.
private struct ShownCopyOnly: ViewModifier {
    @Environment(\.heroReports) private var shown
    func body(content: Content) -> some View {
        content.accessibilityHidden(true, isEnabled: !shown)
    }
}
