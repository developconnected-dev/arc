import SwiftUI
import SwiftData

/// The My Flights sheet content: title + share/avatar, then active & upcoming
/// flights as countdown cards. A flight stays here for 30 minutes after
/// landing too (arrival gate, baggage claim still visible) before moving
/// exclusively to Passport history.
struct MyFlightsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Flight.scheduledDeparture) private var allFlights: [Flight]
    var onSelect: (Flight) -> Void
    var onAdd: () -> Void = {}
    /// A trip that just became the user's — an accepted invite is an import,
    /// and gets the same beat an add does: the row appears and the map draws
    /// the route on.
    var onImported: (Flight) -> Void = { _ in }
    /// A tap on an invited trip's card: the root opens its read-only preview
    /// in the tab sheet, gliding from the card.
    var onPreview: (FriendsStore.TripInviteItem, Flight) -> Void = { _, _ in }
    /// Trips that just became the user's, by id. The row appearing is the
    /// confirmation of an add — but a list scrolled even one row down keeps
    /// its place when a row is inserted above it, and the confirmation plays
    /// out of view. Each new batch brings its topmost row to the top.
    var landed: [UUID] = []

    @State private var showSettings = false
    @State private var shareFlight: Flight?
    @State private var friendsStore = FriendsStore.shared

    private var flights: [Flight] { Self.listed(Array(allFlights)) }

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
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 10)

            ScrollViewReader { proxy in
            List {
                // Trips a friend added for the two of you, waiting on an
                // answer. Pinned above everything rather than slotted into
                // the timeline: an invite for a trip six weeks out would
                // otherwise sit below the fold and never be seen.
                // A failed Accept sets lastError and leaves the card — but
                // the error used to render only on the Friends tab, so here
                // the tap just visibly did nothing.
                if let error = friendsStore.lastError, !friendsStore.tripInvites.isEmpty {
                    Text(error)
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 0, trailing: 16))
                }
                ForEach(friendsStore.tripInvites) { item in
                    TripInviteCard(item: item,
                                   onOpen: { onPreview(item, $0) },
                                   onAccept: { accept(item) },
                                   onDecline: { friendsStore.decline(item) })
                        .heroCopy(key: item.id, side: .list)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                }
                if flights.isEmpty {
                    Button(action: onAdd) {
                        emptyState.padding(.top, 40)
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } else {
                    // Flat list, one smooth surface. A connection is bound by
                    // omission and a spine: no divider between its legs, and a
                    // continuous vertical line through the layover row linking
                    // the two countdown blocks — transit-map grammar instead
                    // of a container that breaks the surface.
                    ForEach(Array(flights.enumerated()), id: \.element.id) { idx, flight in
                        Button { onSelect(flight) } label: {
                            FlightRowCard(flight: flight)
                                // The card the detail opens from and closes
                                // back into (see `Morph`).
                                .heroCopy(for: flight, side: .list)
                        }
                            .buttonStyle(.plain)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { delete(flight) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .overlay(alignment: .bottom) {
                                if idx < flights.count - 1, !isConnectionGap(after: idx) {
                                    Divider().padding(.leading, 20)
                                }
                            }
                        if isConnectionGap(after: idx), let plan = connectionPlan {
                            layoverConnector(plan)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        }
                    }
                }
                Color.clear.frame(height: 140)   // clear the floating pill
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .refreshable {
                await FlightTracker.shared.burstUpdate(flights: Array(allFlights), modelContext: modelContext)
                // Pull-to-refresh is also "did anyone add a trip for me?"
                await friendsStore.refresh(force: true)
            }
            .onChange(of: landed) { _, ids in
                guard let row = Self.rowToReveal(ids: Set(ids), among: Array(allFlights)) else { return }
                // The save that produced the batch is already in the query;
                // one turn of the loop lets the List lay the row out before
                // it is asked to show it.
                Task { @MainActor in
                    withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(row, anchor: .top) }
                }
            }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(item: $shareFlight) { flight in
            ShareFlightSheet(flight: flight)
        }
        .onAppear {
            friendsStore.updateAirportOverlaps(with: Array(allFlights))
            friendsStore.reconcileTripInvites(with: Array(allFlights))
            if ProcessInfo.processInfo.arguments.contains("-openSettings") { showSettings = true }
        }
        .onChange(of: allFlights.map(\.id)) { _, _ in
            friendsStore.updateAirportOverlaps(with: Array(allFlights))
            friendsStore.reconcileTripInvites(with: Array(allFlights))
        }
        // Invites for a journey the user already has answer themselves.
        .onChange(of: friendsStore.tripInvites.map(\.id)) { _, _ in
            friendsStore.reconcileTripInvites(with: Array(allFlights))
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

    // MARK: Connection grouping

    /// The one connection among the listed flights, if any — computed from the
    /// same planner the detail screen uses, so both agree on what a journey is.
    private var connectionPair: (inbound: Flight, outbound: Flight)? {
        ConnectionPlanner.detectConnection(from: allFlights)
    }

    private var connectionPlan: ConnectionPlanner.Plan? {
        connectionPair.map { ConnectionPlanner.plan(inbound: $0.inbound, outbound: $0.outbound) }
    }

    /// True when the row at `idx` is the inbound leg and the next row is its
    /// outbound — the gap between them is a layover, not a separator.
    private func isConnectionGap(after idx: Int) -> Bool {
        guard let pair = connectionPair, idx + 1 < flights.count else { return false }
        return flights[idx].id == pair.inbound.id && flights[idx + 1].id == pair.outbound.id
    }

    /// The live layover line between two connected legs: a continuous spine
    /// through the countdown column linking the two legs (no divider between
    /// them), clock, and the planner's verdict — refreshed each minute so
    /// "1h 12m layover" is never yesterday's number.
    private func layoverConnector(_ plan: ConnectionPlanner.Plan) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            let layover = Int(plan.outbound.effectiveDeparture
                .timeIntervalSince(plan.inbound.effectiveArrival) / 60)
            let risk = ConnectionPlanner.risk(neededMinutes: plan.neededMinutes, layoverMinutes: layover)
            let tint: Color = switch risk {
            case .relaxed, .normal: ArcTheme.onTime
            case .tight: .orange
            case .risky: ArcTheme.late
            }
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(tint.opacity(0.45))
                    .frame(width: 2)
                    .frame(width: 52)   // centered under the countdown blocks
                Image(systemName: "clock")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text("\(FriendFlightMath.hmLower(layover)) layover in \(plan.inbound.arrivalIATA) • \(risk.rawValue)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
                Spacer()
            }
            .frame(height: 34)
            // Match FlightRowCard's inner padding so the spine sits exactly
            // under the countdown numbers.
            .padding(.horizontal, 14)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("My Trips").font(ArcTheme.screenTitle)
            Spacer()
            // Shares the trip you're ON if there is one, else the NEXT one —
            // never a leg that already landed, which is what "first" was.
            if let next = flights.first(where: \.isActive) ?? flights.first(where: \.isUpcoming) {
                Button { shareFlight = next } label: {
                    circleIcon("square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share \(next.flightNumberSpaced)")
            }
            Button { showSettings = true } label: {
                ProfileButtonIcon(size: 34)
            }
            .buttonStyle(.plain)
        }
    }

    private func circleIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 36, height: 36)
            .background(Color(.secondarySystemFill), in: Circle())
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "airplane.departure")
                .font(.system(size: 44))
                .foregroundStyle(ArcTheme.smartGradient.opacity(0.75))
            Text("Where to next?")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Search a flight number, route, or just paste your booking email.")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Text("Tap to add a trip")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ArcTheme.action)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }
}
