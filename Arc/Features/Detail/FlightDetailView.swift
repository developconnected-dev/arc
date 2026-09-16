import SwiftUI
import SwiftData

/// A flight's detail, hosted inside the existing tab sheet.
/// Beneath the header, sections use the shared components
/// `DetailRow` / `DetailGroup`: what needs attention, what the traveller
/// wrote down, and the aircraft. See docs/superpowers/specs/
/// 2026-09-12-detail-redesign-design.md.
struct FlightDetailView: View {
    @Bindable var flight: Flight
    var isOwnFlight: Bool = true
    var onShowAtGate: ((Flight) -> Void)? = nil
    var onShowAirport: ((Flight) -> Void)? = nil
    var onOpenFlight: ((Flight) -> Void)? = nil
    /// Inside the tab sheet the detail is not a presentation, so there is
    /// nothing for `dismiss` to dismiss: the root clears `detailFlight` and
    /// the list is revealed. A friend's read-only preview is still a real
    /// sheet and falls back to `dismiss`.
    var onClose: (() -> Void)? = nil
    /// A friend's detail names the person sharing it first.
    var friend: ArcSupabase.ArcUser? = nil
    /// What the friend row says on the right: how this flight reached you.
    var heroKey: String? = nil
    var travelGroup: FriendFlightGroup? = nil
    var transitionActive = false
    var friendNote: String = "Shared with you"
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext

    @State private var editing: EditField?
    @State private var editText = ""
    @State private var audiencePushFailed = false
    @State private var airportSheet: AirportSheetTarget?
    @State private var showShare = false
    @State private var confirmDelete = false
    @State private var connectionExpanded = false
    @State private var aircraftExpanded = false
    @State private var newCompanionIds: [String] = []
    @State private var friendsStore = FriendsStore.shared
    @Query(sort: \Flight.scheduledDeparture) private var allFlights: [Flight]

    private struct AirportSheetTarget: Identifiable { let id: String }

    private var connection: ConnectionPlanner.Plan? {
        guard let pair = ConnectionPlanner.detectConnection(from: allFlights),
              pair.inbound.id == flight.id || pair.outbound.id == flight.id
        else { return nil }
        return ConnectionPlanner.plan(inbound: pair.inbound, outbound: pair.outbound)
    }

    enum EditField: String, Identifiable { case bookingCode, seat, notes; var id: String { rawValue } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    DetailHeader(flight: flight, isOwnFlight: isOwnFlight,
                                 onShowAtGate: onShowAtGate, onShowAirport: onShowAirport,
                                 onAirport: flight.mode == .air ? { airportSheet = AirportSheetTarget(id: $0) } : nil)
                        .heroCopy(key: heroKey ?? flight.id.uuidString, side: .detail)
                    Group {
                        if let travelGroup {
                            travellersSection(travelGroup)
                        } else if let friend { friendSection(friend) }
                        statusSection
                        if isOwnFlight, flight.status == .landed {
                            JourneyRecapCard(flight: flight)
                        }
                        if isOwnFlight {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Your trip").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                tripSection
                            }
                        }
                        if isOwnFlight, flight.mode == .air, !flight.isCompleted { aircraftSection }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                // Presented as a system sheet (a friend's invite preview) the
                // content needs room under the sheet's own drag indicator. In
                // the tab sheet the menu and X sit in the grabber row, and
                // the top line needs a breath beneath them so the status pill
                // is not wedged against the X.
                .padding(.top, onClose == nil ? 26 : 12)
                .padding(.bottom, 40)
            }
            .modifier(PanelScrollReader())
            .onAppear {
                let args = ProcessInfo.processInfo.arguments
                if args.contains("-detailPlane") { aircraftExpanded = true }
                let target = args.contains("-detailBottom") ? "bottom" : args.contains("-detailPlane") ? "plane" : nil
                if let target {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { proxy.scrollTo(target, anchor: target == "plane" ? .top : .bottom) }
                    }
                }
            }
            .onChange(of: aircraftExpanded) { _, expanded in
                guard expanded else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { proxy.scrollTo("plane", anchor: .top) }
                }
            }
        }
        .task(id: transitionActive) {
            guard !transitionActive, isOwnFlight, !flight.isCompleted else { return }
            await FlightTracker.shared.burstUpdate(flights: [flight], modelContext: modelContext)
            if flight.isUpcoming {
                await InboundMonitor.checkInbound(for: flight)
                try? modelContext.save()
            }
        }
        .overlay(alignment: .topTrailing) {
            // The menu and the X live in the grabber row, beside the handle,
            // so the card can be the first line of the sheet.
            if onClose != nil {
                HStack(spacing: 10) {
                    if isOwnFlight { menuButton }
                    closeButton
                }
                .padding(.trailing, 16)
                // Its own container: in the floating panel, a friend's detail
                // (the X alone here) scrolling past the panel's edge gave the
                // X the whole panel's frame, and taps on its centre missed.
                .accessibilityElement(children: .contain)
                // Centred on the grabber's capsule, so the circles have the
                // same 8pt to the sheet's edge as the header's top line has
                // to them (see `BottomSheet`).
                .offset(y: -13 - controlSize / 2)
            }
        }
        .confirmationDialog("Delete this flight?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete \(flight.flightNumberSpaced)", role: .destructive) {
                Task {
                    await Flight.delete(flight, from: modelContext)
                    close()
                }
            }
        }
        .sheet(item: $airportSheet) { target in
            AirportStatusView(iata: target.id)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showShare) {
            ShareFlightSheet(flight: flight)
        }
        .alert(editTitle,
               isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } }),
               presenting: editing) { field in
            TextField(editTitle, text: $editText)
            Button("Cancel", role: .cancel) { editing = nil }
            Button("Save") { saveEdit(field) }
        }
        .alert("Couldn't update sharing", isPresented: $audiencePushFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Who can see this flight wasn't updated on the server. Check your connection and change it again.")
        }
    }

    // MARK: Grabber-row controls

    private var closeButton: some View {
        Button { close() } label: { circleIcon("xmark") }
            .buttonStyle(.plain)
            .accessibilityLabel("Close trip details")
            .accessibilityIdentifier("trip-detail-close")
    }

    private var menuButton: some View {
        Menu {
            Button { showShare = true } label: { Label("Share Flight", systemImage: "square.and.arrow.up") }
            Button { UIPasteboard.general.string = flight.flightNumberSpaced } label: {
                Label("Copy Flight Number", systemImage: "doc.on.doc")
            }
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Flight", systemImage: "trash") }
        } label: { circleIcon("ellipsis") }
        .buttonStyle(.plain)
        .accessibilityLabel("Trip actions")
    }

    /// The menu and the X: comfortable to hit, and sized to the 15pt text
    /// they sit beside rather than to the grabber's capsule.
    private let controlSize: CGFloat = 44

    private func circleIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 34, height: 34)
            .background(Color(.secondarySystemFill), in: Circle())
            .frame(width: controlSize, height: controlSize)
            .contentShape(Rectangle())
    }

    // MARK: Whose flight

    private func travellersSection(_ group: FriendFlightGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Travelling together").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            DetailGroup {
                if group.myFlightID != nil {
                    Label("You’re on this flight", systemImage: "person.crop.circle.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(ArcTheme.brand)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                ForEach(group.users.sorted { $0.id < $1.id }, id: \.id) { user in
                    HStack(spacing: 12) {
                        FriendAvatar(name: user.display_name, size: 28, avatarURL: user.avatar_url)
                        Text(user.display_name).font(.subheadline)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
        }
        .accessibilityIdentifier("trip-travellers")
    }

    private func friendSection(_ user: ArcSupabase.ArcUser) -> some View {
        DetailGroup {
            HStack(spacing: 12) {
                FriendAvatar(name: user.display_name, size: 24, avatarURL: user.avatar_url)
                Text("\(user.display_name)'s flight").font(.system(size: 15))
                Spacer(minLength: 8)
                Text(friendNote).font(.system(size: 15)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
    }

    // MARK: Status — only what needs attention

    @ViewBuilder private var statusSection: some View {
        let inbound = inboundLine
        let plan = connection
        if inbound != nil || plan != nil {
            DetailGroup {
                if let inbound {
                    DetailRow(icon: "arrow.triangle.2.circlepath", text: inbound,
                              chevron: flight.isUpcoming && flight.aircraftRegistration != nil,
                              action: flight.isUpcoming && flight.aircraftRegistration != nil
                                  ? { withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { aircraftExpanded = true } } : nil)
                }
                if let plan {
                    let other = plan.inbound.id == flight.id ? plan.outbound : plan.inbound
                    let where_ = plan.inbound.arrivalIATA
                    DetailRow(icon: "arrow.triangle.branch",
                              text: "\(FlightClock.delayText(plan.layoverMinutes)) layover in \(where_)",
                              subtitle: plan.inbound.id == flight.id
                                  ? "Then \(other.flightNumberSpaced) to \(other.arrivalCity)"
                                  : "From \(other.flightNumberSpaced) out of \(other.departureCity)",
                              value: plan.risk.rawValue,
                              valueColor: plan.risk == .risky ? ArcTheme.late : (plan.risk == .tight ? .orange : ArcTheme.onTime),
                              chevron: true) {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { connectionExpanded.toggle() }
                    }
                }
            }
        }
        if connectionExpanded, let plan {
            ConnectionCard(plan: plan, currentFlightID: flight.id, onSelectOther: onOpenFlight)
                .transition(.opacity)
        }
        if !flight.isCompleted, !flight.isActive, flight.mode == .air {
            DelayRiskCard(flight: flight)
        }
        if !flight.isCompleted, flight.mode == .air {
            AirportOverlapRow(flight: flight)
        }
    }

    private var inboundLine: String? {
        if flight.isActive {
            if flight.isDepartingUnconfirmed {
                return flight.mode == .air ? "Waiting for takeoff confirmation" : "Waiting for departure confirmation"
            }
            return flight.isDataFresh ? "Live tracking active" : "Tracking — waiting for fresh data"
        }
        guard flight.isUpcoming, flight.aircraftRegistration != nil else { return nil }
        if !flight.inboundChecked { return "Checking inbound aircraft" }
        if let leg = flight.rotationLegs.last,
           leg.status == "landed" || (leg.effectiveArrival.map { $0 <= .now } ?? false) {
            return "Inbound aircraft has arrived"
        }
        if flight.inboundDelayMinutes > 0 { return "Inbound aircraft is \(FlightClock.delayText(flight.inboundDelayMinutes)) late" }
        if flight.inboundFlightNumber != nil { return "Inbound aircraft on schedule" }
        return nil
    }

    // MARK: Your trip

    private var tripSection: some View {
        DetailGroup {
            if TripGroup.isEmpty(flight) {
                Menu {
                    Button("Booking code") { editField(.bookingCode) }
                    Button("Seat") { editField(.seat) }
                    Button("Notes") { editField(.notes) }
                } label: {
                    DetailRow(icon: "plus.circle", text: "Add booking code, seat or notes", chevron: true)
                }
                .buttonStyle(.plain)
            } else {
                DetailRow(icon: "ticket", text: "Booking code",
                          value: (flight.bookingCode ?? "").isEmpty ? "Add" : flight.bookingCode!,
                          valueColor: (flight.bookingCode ?? "").isEmpty ? ArcTheme.action : Color(.secondaryLabel)) {
                    editField(.bookingCode)
                }
                DetailRow(icon: "chair", text: "Seat",
                          value: (flight.seat ?? "").isEmpty ? "Add" : flight.seat!,
                          valueColor: (flight.seat ?? "").isEmpty ? ArcTheme.action : Color(.secondaryLabel)) {
                    editField(.seat)
                }
                DetailRow(icon: "note.text", text: flight.notes.isEmpty ? "Notes" : flight.notes,
                          value: flight.notes.isEmpty ? "Add" : "",
                          valueColor: ArcTheme.action) {
                    editField(.notes)
                }
            }
            if ArcSupabase.shared.isSignedIn && !FriendsStore.shared.friends.isEmpty {
                TravelCompanionsRow(travellingWithIds: $newCompanionIds,
                                    lockedIds: friendsStore.invitedIds(for: flight),
                                    onDone: sendPendingCompanionInvites)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .onChange(of: newCompanionIds) { _, ids in
                        let widened = TripCompanions.audience(sharedWithIds: flight.sharedWithIds, travellingWithIds: ids)
                        if widened != flight.sharedWithIds { flight.sharedWithIds = widened }
                    }
                    .onDisappear { sendPendingCompanionInvites() }
                FlightAudienceRow(sharedWithIds: Binding(
                    get: { flight.sharedWithIds },
                    set: { flight.sharedWithIds = $0 }),
                    onDone: {
                        try? modelContext.save()
                        let f = flight
                        Task {
                            do { _ = try await ArcSupabase.shared.shareFlight(f) }
                            catch { audiencePushFailed = true }
                        }
                    })
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
            ForEach(invitedCompanions, id: \.id) { user in
                companionRow(name: user.display_name, avatarURL: user.avatar_url,
                             detail: "Invited · waiting for them to accept", dim: true)
            }
            ForEach(Array(companions.enumerated()), id: \.offset) { _, comp in
                companionRow(name: comp.user.display_name, avatarURL: comp.user.avatar_url,
                             detail: comp.seat.map { "Seat \($0)" } ?? "No seat shared", dim: false)
            }
        }
    }

    private func companionRow(name: String, avatarURL: String?, detail: String, dim: Bool) -> some View {
        HStack(spacing: 12) {
            FriendAvatar(name: name, size: 24, avatarURL: avatarURL)
                .opacity(dim ? 0.55 : 1)
            Text(name).font(.system(size: 15)).foregroundStyle(dim ? .secondary : .primary)
            Spacer(minLength: 8)
            Text(detail).font(.system(size: 15)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    // MARK: Aircraft

    private var aircraftSection: some View {
        DetailGroup {
            DetailRow(icon: "airplane", text: flight.aircraftType ?? "Aircraft",
                      subtitle: aircraftContext,
                      value: flight.aircraftRegistration ?? "",
                      chevron: true) {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { aircraftExpanded.toggle() }
            }
            .id("plane")
            if aircraftExpanded {
                if flight.showsPrediction, let reason = flight.predictionReason {
                    DetailRow(icon: "sparkles", text: "Arc predicts ~\(FlightClock.delayText(flight.predictedDelayMinutes)) late",
                              subtitle: reason)
                }
                ForEach(Array(flight.rotationLegs.reversed().enumerated()), id: \.offset) { _, leg in
                    let d = RotationLegDisplay.make(leg)
                    DetailRow(icon: d.symbol, text: "\(leg.flightNumber) · \(leg.depIATA) → \(leg.arrIATA)",
                              subtitle: d.statusText,
                              value: d.timeText.map { "\($0) \(d.timeCaption)" } ?? "")
                }
                if flight.rotationLegs.isEmpty, let number = flight.inboundFlightNumber {
                    DetailRow(icon: "arrow.turn.down.right", text: number,
                              subtitle: flight.inboundRoute ?? "Inbound to \(flight.departureIATA)")
                }
            }
        }
    }

    private var aircraftContext: String? {
        if flight.aircraftRegistration == nil { return "Aircraft not yet assigned" }
        if !flight.inboundChecked { return "Checking previous rotation" }
        if flight.inboundFlightNumber == nil { return "No prior rotation found" }
        if flight.inboundDelayMinutes > 0 { return "Running \(FlightClock.delayText(flight.inboundDelayMinutes)) late on its earlier legs" }
        return "On schedule so far today"
    }

    // MARK: Editing

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private var editTitle: String {
        switch editing {
        case .bookingCode: "Booking Code"; case .seat: "Seat"; case .notes: "Notes"; case .none: ""
        }
    }

    private func editField(_ field: EditField) {
        editText = field == .bookingCode ? (flight.bookingCode ?? "") : field == .seat ? (flight.seat ?? "") : flight.notes
        editing = field
    }

    private func saveEdit(_ field: EditField) {
        switch field {
        case .bookingCode: flight.bookingCode = editText
        case .seat: flight.seat = editText
        case .notes: flight.notes = editText
        }
        try? modelContext.save()
        let f = flight
        Task {
            await LiveActivityManager.shared.updateActivity(for: f)
            try? await ArcSupabase.shared.upsertUserFlight(f)
            _ = try? await ArcSupabase.shared.shareFlight(f)
        }
        editing = nil
    }

    private func sendPendingCompanionInvites() {
        let ids = newCompanionIds
        guard !ids.isEmpty else { return }
        newCompanionIds = []
        let flight = self.flight
        Task {
            do {
                _ = try? await ArcSupabase.shared.shareFlight(flight)
                try await ArcSupabase.shared.sendTripInvites(flight, to: ids)
                await FriendsStore.shared.refreshSentTripInvites()
            } catch {
                FriendsStore.shared.noteUnsentInvites(for: flight, ids: ids)
            }
        }
    }

    private var companions: [(user: ArcSupabase.ArcUser, seat: String?)] {
        FriendsStore.shared.companions(for: flight)
    }

    private var invitedCompanions: [ArcSupabase.ArcUser] {
        guard isOwnFlight else { return [] }
        let confirmed = Set(companions.map(\.user.id))
        return friendsStore.pendingCompanions(for: flight).filter { !confirmed.contains($0.id) }
    }
}
