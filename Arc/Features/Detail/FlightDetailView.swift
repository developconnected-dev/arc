import SwiftUI
import SwiftData

/// Flighty-parity flight detail, presented as a bottom sheet over the shared map.
struct FlightDetailView: View {
    @Bindable var flight: Flight
    /// False when showing a FRIEND's flight: personal sections (booking,
    /// seat, notes, my-plane tracking, my route history) are yours, not
    /// theirs — they disappear.
    var isOwnFlight: Bool = true
    var onShowAtGate: ((Flight) -> Void)? = nil
    var onShowAirport: ((Flight) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var editing: EditField?
    @State private var editText = ""
    @State private var airportSheet: AirportSheetTarget?
    @State private var showShare = false
    @State private var confirmDelete = false
    @Query(sort: \Flight.scheduledDeparture) private var allFlights: [Flight]

    private struct AirportSheetTarget: Identifiable { let id: String }

    /// The connection this flight belongs to, if any (as either leg).
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
                VStack(spacing: 18) {
                    header
                    statusBanner
                    if !companions.isEmpty {
                        companionsCard
                    }
                    endpointsCard
                    // Only when the airline has actually assigned a belt. The
                    // old fallback invented "7 (Belt Confirmed)" for any landed
                    // flight — a made-up number presented as confirmed.
                    if let belt = flight.baggageClaim, !belt.isEmpty {
                        BaggageCarouselSection(flight: flight, belt: belt)
                    }
                    mapActionsRow
                    if !flight.isCompleted {
                        AirportOverlapRow(flight: flight)
                        DelayRiskCard(flight: flight)
                    }
                    if isOwnFlight { bookingSeatRow; audienceCard }
                    GoodToKnowSection(flight: flight)
                    if let plan = connection {
                        ConnectionCard(plan: plan, currentFlightID: flight.id)
                    }
                    if isOwnFlight { WheresMyPlaneSection(flight: flight).id("plane") }
                    DetailedTimetableSection(flight: flight)
                    AirlineInfoSection(flight: flight)
                    if isOwnFlight {
                        RouteHistorySection(flight: flight)
                        NotesSection(flight: flight) { editField(.notes) }
                        actionBar
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
            .onAppear {
                let args = ProcessInfo.processInfo.arguments
                let target = args.contains("-detailBottom") ? "bottom" : args.contains("-detailPlane") ? "plane" : nil
                if let target {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        withAnimation { proxy.scrollTo(target, anchor: target == "plane" ? .top : .bottom) }
                    }
                }
            }
        }
        .presentationDragIndicator(.visible)
        .sheet(item: $airportSheet) { target in
            AirportStatusView(iata: target.id)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showShare) {
            ShareFlightSheet(flight: flight)
        }
        .alert(editTitle, isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField(editTitle, text: $editText)
            Button("Cancel", role: .cancel) { editing = nil }
            Button("Save") { saveEdit() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            AirlineLogoView(iata: flight.airlineCode, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(flight.flightNumberSpaced) • \(flight.headerDateText)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                cityPair
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(Color(.secondarySystemFill), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var cityPair: some View {
        TextHelpers.cityPair(flight.departureCity, flight.arrivalCity, size: 24)
            .lineLimit(2)
    }

    // MARK: Status banner

    private var statusBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Text(flight.bannerHeadline)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(flight.bannerColor)
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(flight.isDataFresh ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(flight.dataFreshnessText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(uiColor: .systemBackground).opacity(0.6), in: Capsule())
            }
            if let inbound = inboundLine {
                HStack(spacing: 4) {
                    Text(inbound).font(.system(size: 14)).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
            // Name the clock. The times are correct and match the booking, but
            // nothing said they were airport-local, so they read as wrong
            // whenever the phone was in a different zone.
            if let note = flight.timezoneNote {
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 12, weight: .semibold))
                    Text(note).font(.system(size: 13))
                }
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
            // Say out loud that these are the times you typed and that Arc is
            // still looking, so nobody wonders whether it quietly gave up.
            if flight.awaitingSchedule {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Your times — checking daily for the airline's schedule")
                        .font(.system(size: 13))
                }
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(flight.bannerColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Inbound-aircraft status only makes sense while something is still
    /// actively being tracked — a landed/cancelled flight already happened,
    /// so "checking inbound aircraft" would misleadingly read as present-tense.
    private var inboundLine: String? {
        if flight.isActive { return "Live tracking active" }
        guard flight.isUpcoming, flight.aircraftRegistration != nil else { return nil }
        if !flight.inboundChecked { return "Checking inbound aircraft" }
        // The best possible pre-departure news (Flighty parity): the tail
        // that flies YOUR leg is already on the ground at your airport.
        if let leg = flight.rotationLegs.last,
           leg.status == "landed" || (leg.effectiveArrival.map { $0 <= .now } ?? false) {
            return "Inbound aircraft has arrived"
        }
        if flight.inboundDelayMinutes > 0 { return "Inbound aircraft is \(flight.inboundDelayMinutes)m late" }
        if flight.inboundFlightNumber != nil { return "Inbound aircraft on schedule" }
        return nil
    }

    // MARK: Endpoints

    private var endpointsCard: some View {
        VStack(spacing: 0) {
            endpoint(isArrival: false)
            HStack(spacing: 8) {
                Image(systemName: "clock").font(.system(size: 12)).foregroundStyle(.tertiary)
                Text("\(flight.durationFormatted) • \(flight.distanceFormatted)")
                    .font(.system(size: 13)).foregroundStyle(.tertiary)
                Rectangle().fill(Color(.separator)).frame(height: 0.5)
            }
            .padding(.vertical, 10)
            endpoint(isArrival: true)
        }
    }

    /// In-app terminal map (cinematic dive onto satellite imagery with every
    /// OSM gate labeled) and, after landing, the plane parked at its actual
    /// arrival gate.
    private var mapActionsRow: some View {
        HStack(spacing: 10) {
            // Only rendered when a host wired the closure — a friend's
            // flight opens this detail without map actions, and a dead
            // button would be worse than none.
            if onShowAirport != nil {
            Button {
                onShowAirport?(flight)
            } label: {
                Label("Terminal Map", systemImage: "map")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            }

            if flight.isUpcoming, onShowAtGate != nil {
                Button { onShowAtGate?(flight) } label: {
                    Label(flight.departureGate.map { "My plane · Gate \($0)" } ?? "My plane",
                          systemImage: "airplane.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(ArcTheme.action.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(ArcTheme.action)
                }
                .buttonStyle(.plain)
            } else if flight.isCompleted || flight.isRecentlyLanded, let gate = flight.arrivalGate, onShowAtGate != nil {
                Button { onShowAtGate?(flight) } label: {
                    Label("Plane at \(gate)", systemImage: "airplane.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(ArcTheme.action.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(ArcTheme.action)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func endpoint(isArrival: Bool) -> some View {
        let iata = isArrival ? flight.arrivalIATA : flight.departureIATA
        let name = isArrival ? flight.arrivalAirportName : flight.departureAirportName
        let time = isArrival ? flight.effectiveArrTimeLocal : flight.effectiveDepTimeLocal
        let schedTime = isArrival ? flight.arrTimeLocal : flight.depTimeLocal
        let changed = isArrival ? flight.arrivalChanged : flight.departureChanged
        let statusText = isArrival ? flight.arrivalStatusText : flight.departureStatusText
        let relText = isArrival ? flight.arrivalRelText : flight.departureRelText
        let gate = isArrival ? flight.arrivalGate : flight.departureGate
        let terminal = isArrival ? flight.arrivalTerminal : flight.departureTerminal
        let arrow = isArrival ? "arrow.down.right" : "arrow.up.right"

        return VStack(alignment: .leading, spacing: 8) {
            Button { airportSheet = AirportSheetTarget(id: iata) } label: {
                HStack(spacing: 6) {
                    Image(systemName: arrow).font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(.systemBackground))
                        .frame(width: 18, height: 18).background(Color.primary, in: Circle())
                    Text(iata).font(.system(size: 15, weight: .bold))
                    Text("• \(name)").font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(time).font(.system(size: 40, weight: .regular))
                            .foregroundStyle(flight.bannerColor)
                        if changed {
                            Text(schedTime).font(.system(size: 17))
                                .strikethrough().foregroundStyle(.secondary)
                        }
                    }
                    // Completed flights drop the relative clock ("39d 8h ago"
                    // says nothing useful about a flight already flown).
                    Text(flight.isCompleted ? statusText : "\(statusText) • \(relText)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(flight.bannerColor)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    GatePill(arrow: arrow, gate: gate ?? "--")
                    if let terminal { Text("Terminal \(terminal)").font(.system(size: 13)).foregroundStyle(.secondary) }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Booking / Seat

    private var bookingSeatRow: some View {
        HStack(spacing: 12) {
            editCard(title: "Booking Code", value: flight.bookingCode, icon: "ticket") { editField(.bookingCode) }
            editCard(title: "Seat", value: flight.seat, icon: "chair") { editField(.seat) }
        }
    }

    /// Change who sees this flight after the fact. Writing to the model isn't
    /// enough on its own — the shared row has to be re-pushed (or pulled) right
    /// away, otherwise the change only lands on the next tracking poll, and a
    /// flight you just made private stays visible until then.
    @ViewBuilder private var audienceCard: some View {
        if ArcSupabase.shared.isSignedIn && !FriendsStore.shared.friends.isEmpty {
            FlightAudienceRow(sharedWithIds: Binding(
                get: { flight.sharedWithIds },
                set: { newValue in
                    flight.sharedWithIds = newValue
                    Task { try? await ArcSupabase.shared.shareFlight(flight) }
                }))
                .padding(14)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func editCard(title: String, value: String?, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(.primary)
                Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(.primary)
                Text(value?.isEmpty == false ? value! : "Tap to Edit")
                    .font(.system(size: 13))
                    .foregroundStyle(value?.isEmpty == false ? ArcTheme.action : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    // MARK: Action bar

    /// Share works; the bell was a decoration with nothing behind it and is
    /// gone — a control that does nothing teaches people to stop tapping.
    private var actionBar: some View {
        HStack(spacing: 14) {
            Button { showShare = true } label: { actionIcon("square.and.arrow.up") }
                .buttonStyle(.plain)
            Menu {
                Button {
                    UIPasteboard.general.string = flight.flightNumberSpaced
                } label: {
                    Label("Copy Flight Number", systemImage: "doc.on.doc")
                }
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Delete Flight", systemImage: "trash")
                }
            } label: { actionIcon("ellipsis") }
            Spacer()
        }
        .confirmationDialog("Delete this flight?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete \(flight.flightNumberSpaced)", role: .destructive) {
                Task {
                    await Flight.delete(flight, from: modelContext)
                    dismiss()
                }
            }
        }
    }

    private func actionIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 17, weight: .medium))
            .foregroundStyle(.primary).frame(width: 44, height: 44)
            .background(Color(.secondarySystemFill), in: Circle())
    }

    // MARK: Editing

    private var editTitle: String {
        switch editing {
        case .bookingCode: "Booking Code"; case .seat: "Seat"; case .notes: "Notes"; case .none: ""
        }
    }
    private func editField(_ field: EditField) {
        editText = field == .bookingCode ? (flight.bookingCode ?? "") : field == .seat ? (flight.seat ?? "") : flight.notes
        editing = field
    }
    private func saveEdit() {
        switch editing {
        case .bookingCode: flight.bookingCode = editText
        case .seat: flight.seat = editText
        case .notes: flight.notes = editText
        case .none: break
        }
        try? modelContext.save()
        editing = nil
    }

    // MARK: - Smart Friends & Honest Delay Extensions
    private var companions: [(user: ArcSupabase.ArcUser, seat: String?)] {
        FriendsStore.shared.companions(for: flight)
    }

    private var companionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "person.2.fill")
                    .foregroundColor(ArcTheme.brand)
                Text("On This Flight")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Text("\(companions.count) \(companions.count == 1 ? "Friend" : "Friends")")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Divider()
            ForEach(Array(companions.enumerated()), id: \.offset) { _, comp in
                HStack(spacing: 12) {
                    FriendAvatar(name: comp.user.display_name, size: 36, avatarURL: comp.user.avatar_url)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(comp.user.display_name)
                            .font(.system(size: 16, weight: .semibold))
                        if let seat = comp.seat, !seat.isEmpty {
                            Text("Seat \(seat)" + (flight.seat != nil ? " (vs your seat \(flight.seat!))" : ""))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(ArcTheme.brand)
                        } else {
                            Text("No seat shared")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

}
