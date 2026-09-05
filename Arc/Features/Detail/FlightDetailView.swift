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
    var onOpenFlight: ((Flight) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var editing: EditField?
    @State private var editText = ""
    /// The audience change never reached the server — shown as an alert
    /// because for a completed flight no later poll will heal it.
    @State private var audiencePushFailed = false
    @State private var airportSheet: AirportSheetTarget?
    @State private var showShare = false
    @State private var confirmDelete = false
    @State private var pendingScroll: String?
    /// Friends picked as companions on THIS screen, not yet invited — sent
    /// when the sheet closes (see `sendPendingCompanionInvites`).
    @State private var newCompanionIds: [String] = []
    @State private var friendsStore = FriendsStore.shared
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
                    // Ordered by urgency of the traveler's questions:
                    // what's happening (banner, Arc's read, the connection
                    // verdict) → the flight itself (times, baggage, maps) →
                    // context (people, good-to-know, aircraft) → records.
                    header
                    statusBanner
                    // METAR / airport-history reasoning — meaningless for a
                    // train or ferry, so air only.
                    // …and only before departure: a departure-weather outlook
                    // for a plane already in the air is a forecast of the past.
                    if !flight.isCompleted, !flight.isActive, flight.mode == .air {
                        DelayRiskCard(flight: flight)
                    }
                    if let plan = connection {
                        ConnectionCard(plan: plan, currentFlightID: flight.id,
                                       onSelectOther: onOpenFlight)
                    }
                    // Only when the airline has actually assigned a belt. The
                    // old fallback invented "7 (Belt Confirmed)" for any landed
                    // flight — a made-up number presented as confirmed.
                    // And only once a belt can matter: FIDS often publish one
                    // before departure, and "BAGGAGE RECLAIM · Belt 7" above
                    // tomorrow's departure reads as if the trip were over.
                    if flight.showsBaggageBelt, let belt = flight.baggageClaim {
                        BaggageCarouselSection(flight: flight, belt: belt)
                    }
                    endpointsCard
                    mapActionsRow
                    // Overlaps match on airport IATA — a rail leg's "BER" is
                    // Berlin Hbf, and matching it against friends at Berlin
                    // Brandenburg would invent a meetup. Air only.
                    if !flight.isCompleted, flight.mode == .air {
                        AirportOverlapRow(flight: flight)
                    }
                    if !companions.isEmpty || !invitedCompanions.isEmpty {
                        companionsCard
                    }
                    if isOwnFlight { bookingSeatRow; audienceCard }
                    GoodToKnowSection(flight: flight)
                    // Aircraft rotation, tail registration and the silhouette
                    // are all about a plane. A ferry has a vessel and a train
                    // has neither, so this whole section is air-only until each
                    // has something of its own to say.
                    // Once the flight is over there is no plane to find, and the
                    // rotation list would be a stale snapshot of that morning.
                    if isOwnFlight, flight.mode == .air, !flight.isCompleted {
                        WheresMyPlaneSection(flight: flight).id("plane")
                    }
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
                    // Long delay on purpose: at launch this whole screen is
                    // still laying out, and scrollTo before that is a no-op.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        withAnimation { proxy.scrollTo(target, anchor: target == "plane" ? .top : .bottom) }
                    }
                }
            }
            // A tap, by contrast, happens long after layout — one frame is
            // enough, and waiting any longer just feels unresponsive.
            .onChange(of: pendingScroll) { _, target in
                guard let target else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation { proxy.scrollTo(target, anchor: target == "plane" ? .top : .bottom) }
                    pendingScroll = nil
                }
            }
        }
        .presentationDragIndicator(.visible)
        // Opening the detail is the strongest possible "I want fresh data
        // NOW" signal — poll immediately instead of waiting out the global
        // tracking interval.
        .task(id: flight.id) {
            guard isOwnFlight, !flight.isCompleted else { return }
            await FlightTracker.shared.burstUpdate(flights: [flight], modelContext: modelContext)
            // Re-run the knock-on prediction too — the tracker's own inbound
            // check rides a 15-minute throttle, but opening the detail is a
            // user-initiated "is my plane still on time?" and deserves a
            // fresh answer. The SmartLabel sweeps when the number changes.
            if flight.isUpcoming {
                await InboundMonitor.checkInbound(for: flight)
                try? modelContext.save()
            }
        }
        .sheet(item: $airportSheet) { target in
            AirportStatusView(iata: target.id)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showShare) {
            ShareFlightSheet(flight: flight)
        }
        // The `presenting:` variant, and that is the whole fix (same idiom as
        // ManageFriendsSheet's removal alert): dismissing the alert flips
        // isPresented false BEFORE the button action runs, and that flip nils
        // `editing` through the binding — so a Save that re-read `editing`
        // found .none and silently dropped every edit while the card went on
        // saying "Tap to Edit".
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

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            TripLogoView(mode: flight.mode, iata: flight.airlineCode,
                         logoURL: flight.operatorLogoURL, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(flight.flightNumberSpaced) • \(flight.headerDateText)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                // There's room here for the whole story, so say it in words:
                // the number above is what flies, this is what's on the
                // ticket. Same fact the list row compresses into "· A3 1653".
                if let marketing = flight.marketingLabel {
                    Text("Booked as \(marketing)")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
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
                    .contentTransition(.opacity)
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(flight.isDataFresh && flight.reportsPunctuality ? Color.green
                              : (flight.isDataFresh ? Color(.secondaryLabel) : Color.orange))
                        .frame(width: 6, height: 6)
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Text(flight.dataFreshnessText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(uiColor: .systemBackground).opacity(0.6), in: Capsule())
            }
            if let inbound = inboundLine {
                // The chevron promises a jump to "Where's My Plane?" — which
                // only exists for your own air legs. Without that section to
                // scroll to it's a dead affordance, so it isn't drawn at all
                // rather than drawn and disabled.
                if isOwnFlight, flight.mode == .air {
                    Button {
                        pendingScroll = "plane"
                    } label: {
                        HStack(spacing: 4) {
                            Text(inbound).font(.system(size: 14)).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows this aircraft's day")
                } else {
                    Text(inbound).font(.system(size: 14)).foregroundStyle(.secondary)
                }
            }
            // Airborne: the widget's system-animated progress bar lives INSIDE
            // the banner — one card says everything, instead of a second card
            // repeating the countdown right below. Not while the departure is
            // still unconfirmed: a moving bar IS a claim the flight left, and
            // the Live Activity's departing view draws none either.
            if flight.isActive, !flight.isDepartingUnconfirmed {
                let dep = flight.actualDeparture ?? flight.scheduledDeparture
                let arr = max(flight.effectiveArrival, dep.addingTimeInterval(60))
                HStack(spacing: 10) {
                    Text(flight.departureIATA)
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(.secondary)
                    ProgressView(
                        timerInterval: min(dep, arr - 60)...arr,
                        countsDown: false,
                        label: { EmptyView() },
                        currentValueLabel: { EmptyView() }
                    )
                    .progressViewStyle(.linear)
                    .tint(flight.bannerColor)
                    Text(flight.arrivalIATA)
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
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
            // The backfill stops looking once the typed departure has passed,
            // so past that point say what's true: the times are yours.
            if flight.awaitingSchedule {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                        .font(.system(size: 12, weight: .semibold))
                    Text(flight.scheduledDeparture > .now
                         ? "Your times — checking daily for the airline's schedule"
                         : "Your times — no airline schedule was found for this flight")
                        .font(.system(size: 13))
                }
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(flight.bannerColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        // Status flips (On Time → Delayed → In Air) crossfade instead of
        // snapping — the banner is the screen's voice, it shouldn't stutter.
        .animation(.easeInOut(duration: 0.35), value: flight.bannerHeadline)
    }

    /// Inbound-aircraft status only makes sense while something is still
    /// actively being tracked — a landed/cancelled flight already happened,
    /// so "checking inbound aircraft" would misleadingly read as present-tense.
    private var inboundLine: String? {
        // Only claim "live" while the data actually is — saying "Live
        // tracking active" next to a 17-minute-old freshness pill reads as
        // a contradiction, because it is one.
        if flight.isActive {
            // Clock-flipped, nothing confirmed: the same words the Live
            // Activity uses, so the lock screen and this screen can't tell
            // the user two different stories about the same minute.
            if flight.isDepartingUnconfirmed {
                return flight.mode == .air
                    ? "Waiting for takeoff confirmation"
                    : "Waiting for departure confirmation"
            }
            return flight.isDataFresh ? "Live tracking active" : "Tracking — waiting for fresh data"
        }
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
                // Ferry ports carry no coordinates from the provider, so the
                // great-circle distance is 0 — and "0 km" is a false statement,
                // not a missing one. Show the duration alone in that case.
                Text(flight.hasRoute
                     ? "\(flight.durationFormatted) • \(flight.distanceFormatted)"
                     : flight.durationFormatted)
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
            // Both of these are airport features: an OSM terminal map and the
            // aircraft parked at its gate. Neither exists for a station or a
            // quayside, and an button that opens an empty map is worse than no
            // button.
            if onShowAirport != nil, flight.mode == .air, flight.hasRoute {
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

            // "My plane" needs a plane: without a tail (ICAO24/registration)
            // the watch returns immediately and the user is left staring at an
            // empty gate. The Where's My Plane card says "not yet assigned".
            if flight.isUpcoming, onShowAtGate != nil, flight.mode == .air, flight.hasRoute,
               flight.aircraftICAO24?.isEmpty == false || flight.aircraftRegistration?.isEmpty == false {
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
            // A parked plane is only a fact for a LANDED flight, and only for
            // the half hour it plausibly still stands there — not for a
            // cancelled or diverted one, whose aircraft never reached this gate.
            } else if flight.status == .landed, flight.isRecentlyLanded, let gate = flight.arrivalGate,
                      onShowAtGate != nil, flight.mode == .air, flight.hasRoute {
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

        // A station's or port's code is not an airport code — "BER" on a
        // train is Berlin Hbf, and the airport sheet would show Brandenburg's
        // weather as this leg's. Off-air the header is a label, not a button.
        let opensAirport = flight.mode == .air
        let tint = endpointColor(isArrival: isArrival)
        return VStack(alignment: .leading, spacing: 8) {
            Button { if opensAirport { airportSheet = AirportSheetTarget(id: iata) } } label: {
                HStack(spacing: 6) {
                    Image(systemName: arrow).font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(.systemBackground))
                        .frame(width: 18, height: 18).background(Color.primary, in: Circle())
                    Text(iata).font(.system(size: 15, weight: .bold))
                    Text("• \(name)").font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(1)
                    if opensAirport {
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .disabled(!opensAirport)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(time).font(.system(size: 40, weight: .regular))
                            .foregroundStyle(tint)
                            .contentTransition(.numericText())
                            .animation(.default, value: time)
                        if changed {
                            Text(schedTime).font(.system(size: 17))
                                .strikethrough().foregroundStyle(.secondary)
                        }
                    }
                    if isArrival, flight.showsArrivalPrediction {
                        SmartLabel(text: "Predicted", size: 12)
                    }
                    // Completed flights drop the relative clock ("39d 8h ago"
                    // says nothing useful about a flight already flown).
                    // An unconfirmed departure can't be "On Time" — but it can
                    // certainly be late: the airline publishing a revised gate
                    // time IS a reported delay, and pairing "9m past schedule"
                    // with "no delay reported" beside a struck-through 11:50
                    // simply contradicted itself.
                    Text(flight.isCompleted ? statusText
                         : (!isArrival && (flight.isDepartureUnconfirmed || flight.isDepartingUnconfirmed))
                            ? (flight.isDelayed ? "\(relText) • \(statusText)"
                                                : "\(relText) • no delay reported")
                            : "\(statusText) • \(relText)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    // A flight always has a gate eventually, so an empty pill is
                    // a useful placeholder. A ferry has no gate ever, and a
                    // permanent yellow "--" is just clutter that reads like
                    // missing data — so off-air the pill appears only once there
                    // is a real platform or berth to show.
                    if flight.mode == .air || (gate?.isEmpty == false) {
                        // Tappable only when there is a gate to show AND a
                        // plane to find there — a yellow "--" that flew the map
                        // to an empty apron promised something it couldn't do.
                        let hasTail = flight.aircraftICAO24?.isEmpty == false || flight.aircraftRegistration?.isEmpty == false
                        let pillOpensMap = isOwnFlight && onShowAtGate != nil && flight.mode == .air
                            && gate?.isEmpty == false && flight.hasRoute
                            && ((isArrival && flight.status == .landed && flight.isRecentlyLanded)
                                || (!isArrival && flight.isUpcoming && hasTail))
                        if pillOpensMap, let gate {
                            Button { onShowAtGate?(flight) } label: {
                                GatePill(arrow: arrow, gate: gate)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Show plane at gate \(gate)")
                        } else if !isArrival, flight.showsPredictedGate,
                                  let predicted = flight.predictedDepartureGate {
                            // The airline hasn't gated this yet, but the
                            // flywheel knows what this number usually gets.
                            // Muted pill + the smart mark — a habit wears the
                            // prediction idiom, never the yellow of a fact.
                            VStack(alignment: .trailing, spacing: 3) {
                                GatePill(arrow: arrow, gate: predicted, pending: true)
                                SmartLabel(text: "Predicted", size: 11)
                            }
                            .accessibilityLabel("Predicted gate \(predicted), not yet confirmed")
                        } else {
                            // No gate yet: a quiet placeholder, not a yellow
                            // chip that reads like an assignment.
                            GatePill(arrow: arrow, gate: gate ?? "--", pending: gate == nil)
                        }
                    }
                    if let terminal {
                        Text("Terminal \(terminal)").font(.system(size: 13)).foregroundStyle(.secondary)
                    } else if !isArrival, flight.showsPredictedGate,
                              let predictedTerminal = flight.predictedDepartureTerminal,
                              !predictedTerminal.isEmpty {
                        Text("Usually Terminal \(predictedTerminal)")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Each endpoint is coloured by ITS OWN delta. One flight-wide colour
    /// painted "On Time" red at the arrival of a flight that left late but
    /// will land on time — and the reverse.
    private func endpointColor(isArrival: Bool) -> Color {
        if flight.status == .cancelled || flight.status == .diverted { return ArcTheme.late }
        guard flight.reportsPunctuality else { return flight.bannerColor }
        if !isArrival, flight.isDepartureUnconfirmed || flight.isDepartingUnconfirmed { return Color(.secondaryLabel) }
        // A live remaining-time guess is not a green early fact.
        if isArrival, flight.showsArrivalPrediction { return .orange }
        let effective = isArrival ? flight.effectiveArrival : flight.effectiveDeparture
        let scheduled = isArrival ? flight.scheduledArrival : flight.scheduledDeparture
        return effective.timeIntervalSince(scheduled) >= 60 ? ArcTheme.late : ArcTheme.onTime
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
            // Same two verbs as the add flow: who's ON it, then who may SEE it.
            // Companions picked here are invited the moment the sheet closes;
            // people already invited show ticked and locked.
            VStack(spacing: 0) {
                TravelCompanionsRow(travellingWithIds: $newCompanionIds,
                                    lockedIds: friendsStore.invitedIds(for: flight),
                                    onDone: sendPendingCompanionInvites)
                    .padding(14)
                    .onChange(of: newCompanionIds) { _, ids in
                        // Being on the trip implies seeing it.
                        let widened = TripCompanions.audience(sharedWithIds: flight.sharedWithIds, travellingWithIds: ids)
                        if widened != flight.sharedWithIds { flight.sharedWithIds = widened }
                    }
                Divider().padding(.leading, 39)
                FlightAudienceRow(sharedWithIds: Binding(
                    get: { flight.sharedWithIds },
                    set: { flight.sharedWithIds = $0 }),
                    onDone: {
                        // One push with the final audience, persisted locally.
                        try? modelContext.save()
                        let f = flight
                        Task {
                            // Named when it fails: for a live flight the
                            // tracker's next poll re-pushes anyway, but a
                            // COMPLETED flight is never polled again — a
                            // swallowed failure here left "No one" on screen
                            // while the server kept the old audience forever.
                            do { _ = try await ArcSupabase.shared.shareFlight(f) }
                            catch { audiencePushFailed = true }
                        }
                    })
                    .padding(14)
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            .onDisappear { sendPendingCompanionInvites() }
        }
    }

    /// Fires the invitations chosen on this screen — when the picker closes,
    /// not per tick, so toggling Peter on and off again never sends him
    /// anything. `onDisappear` is the belt to that brace.
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
                // The picker promised "they'll get this trip offered in
                // their own list", and the sheet is long dismissed — queue
                // the invite durably and the reconcile pass keeps sending
                // until the server accepts. Swallowed, the choice evaporated:
                // the row reverted to "Just me" and nobody was ever invited.
                FriendsStore.shared.noteUnsentInvites(for: flight, ids: ids)
            }
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
    private func saveEdit(_ field: EditField) {
        switch field {
        case .bookingCode: flight.bookingCode = editText
        case .seat: flight.seat = editText
        case .notes: flight.notes = editText
        }
        try? modelContext.save()
        // The edit has to travel: repaint the Live Activity now (the seat
        // renders from its content state — waiting for the next tracker pass
        // left the lock screen stale for up to a minute, and looked like the
        // edit hadn't taken), let syncExtras tell the Worker so its next push
        // restates the seat instead of erasing it, and mirror to the cloud
        // rows that the next push-to-start and the companions' screens read.
        let f = flight
        Task {
            await LiveActivityManager.shared.updateActivity(for: f)
            try? await ArcSupabase.shared.upsertUserFlight(f)
            _ = try? await ArcSupabase.shared.shareFlight(f)
        }
        editing = nil
    }

    // MARK: - Smart Friends & Honest Delay Extensions
    private var companions: [(user: ArcSupabase.ArcUser, seat: String?)] {
        FriendsStore.shared.companions(for: flight)
    }

    /// Invited onto this trip, answer still open. Only the sender's own trip
    /// has these; a friend's trip viewed read-only shows none.
    private var invitedCompanions: [ArcSupabase.ArcUser] {
        guard isOwnFlight else { return [] }
        let confirmed = Set(companions.map(\.user.id))
        return friendsStore.pendingCompanions(for: flight).filter { !confirmed.contains($0.id) }
    }

    private var companionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "person.2.fill")
                    .foregroundColor(ArcTheme.brand)
                Text(flight.mode == .air ? "On This Flight" : "On This Trip")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                let n = companions.count + invitedCompanions.count
                Text("\(n) \(n == 1 ? "Friend" : "Friends")")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Divider()
            // Invited but not yet accepted: named, muted, honest about it.
            ForEach(invitedCompanions, id: \.id) { user in
                HStack(spacing: 12) {
                    FriendAvatar(name: user.display_name, size: 36, avatarURL: user.avatar_url)
                        .opacity(0.55)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.display_name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("Invited · waiting for them to accept")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            }
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
