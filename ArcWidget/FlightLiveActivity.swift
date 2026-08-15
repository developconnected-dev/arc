import ActivityKit
import WidgetKit
import SwiftUI
import UIKit

struct FlightLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FlightActivityAttributes.self) { context in
            lockScreenView(context: context)
                // Tap the card (not the Directions pill) → that flight.
                .widgetURL(ArcDeepLink.url(for: context.attributes))
                // Without a tint iOS falls back to its default dark material,
                // so the card was dark even for light-mode users. The tint is
                // trait-resolved: near-opaque WHITE in light (translucent
                // white over the system's dark blur just looked gray), and a
                // frosted translucent black in dark that keeps the wallpaper
                // glow.
                .activityBackgroundTint(Color(uiColor: UIColor { traits in
                    traits.userInterfaceStyle == .dark
                        ? UIColor.black.withAlphaComponent(0.6)
                        : UIColor.white.withAlphaComponent(0.95)
                }))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            let phase = effectivePhase(context.state)
            return DynamicIsland {
                // Flighty's expanded in-flight layout: flight number top-left,
                // seat top-right, then the full-width route/path/countdown
                // stack in the bottom region.
                DynamicIslandExpandedRegion(.leading) {
                    Group {
                        if phase == .inFlight {
                            // The island's rounded corners curve INTO the top of the
                            // leading/trailing regions — content flush with the top
                            // edge gets visually clipped by the bezel. Nudge it down
                            // and inward, clear of the curvature.
                            HStack(spacing: 4) {
                                Image(systemName: context.attributes.mode.symbol)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text(context.attributes.flightNumber)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 6)
                            .padding(.leading, 4)
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(context.attributes.departureIATA)
                                    .font(.system(size: 22, weight: .bold))
                                Text(context.state.departureTime, style: .time)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)
                        }
                    }
                    .widgetURL(ArcDeepLink.url(for: context.attributes))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Group {
                        if phase == .inFlight {
                            if let friend = context.attributes.friendName, !friend.isEmpty {
                                HStack(spacing: 4) {
                                    friendAvatar(context.attributes, size: 15)
                                    Text(friend)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.top, 6)
                                .padding(.trailing, 4)
                            } else if let seat = context.attributes.seat, !seat.isEmpty {
                                HStack(spacing: 3) {
                                    Image(systemName: "carseat.right.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                    Text(seat)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.top, 6)
                                .padding(.trailing, 4)
                            }
                        } else {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(context.attributes.arrivalIATA)
                                    .font(.system(size: 22, weight: .bold))
                                Text(context.state.arrivalTime, style: .time)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(arrivalDelay(context.state) > 0 ? .orange : .secondary)
                            }
                            .padding(.top, 4)
                        }
                    }
                    .widgetURL(ArcDeepLink.url(for: context.attributes))
                }
                DynamicIslandExpandedRegion(.center) {
                    // Empty — route codes live in leading/trailing (pre-flight)
                    // or the bottom stack (in-flight)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Group {
                        if phase == .inFlight {
                            VStack(spacing: 2) {
                                routeRow(attrs: context.attributes, state: context.state)
                                HStack {
                                    Text(departureStatusText(context.state, context.attributes))
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(departureStatusColor(context.state, context.attributes))
                                        .contentTransition(.numericText())
                                    Spacer()
                                    Text(arrivalStatusText(context.state, context.attributes))
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(arrivalStatusColor(context.state, context.attributes))
                                        .contentTransition(.numericText())
                                }
                                FlightPathProgress(state: context.state)
                                    .frame(height: 18)
                                arrivalCountdown(attrs: context.attributes, context.state)
                            }
                        } else if phase == .landed {
                            HStack(spacing: 6) {
                                Image(systemName: isConfirmedLanded(context.state) ? "checkmark.circle.fill" : arrivalSymbol(context.attributes))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.green)
                                Text(isConfirmedLanded(context.state) ? context.attributes.mode.arrivedVerb : "\(context.attributes.mode.arrivingVerb) soon")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.green)
                                if let belt = context.state.baggageClaim {
                                    Text("· Belt \(belt)")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                if let terminal = context.state.arrivalTerminal {
                                    Text("· T\(terminal)")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                gateBadge(context.state.arrivalGate)
                            }
                        } else if phase == .departing {
                            HStack(spacing: 6) {
                                Image(systemName: departureSymbol(context.attributes))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(IntelligenceShimmerText.gradient)
                                IntelligenceShimmerText(
                                    text: "Departing…",
                                    font: .system(size: 12, weight: .bold),
                                    sweep: context.state.departureTime...context.state.departureTime.addingTimeInterval(Self.departureGrace))
                                Text("awaiting confirmation")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                gateBadge(context.state.departureGate)
                            }
                        } else {
                            HStack {
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.green)
                                // Two Texts, not one interpolated Text: a live
                                // TimeDataSource countdown loses its data source
                                // inside string interpolation and renders as
                                // placeholder dashes ("–h ––m").
                                HStack(spacing: 0) {
                                    Text("Departs \(context.attributes.mode.boardingPointLabel) in ")
                                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                    Text.minuteCountdown(to: context.state.departureTime)
                                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.primary)
                                }
                                Spacer()
                                gateBadge(context.state.departureGate)
                            }
                        }
                    }
                    .widgetURL(ArcDeepLink.url(for: context.attributes))
                }
            } compactLeading: {
                Group {
                    // In-flight: Flighty's little self-filling progress ring with
                    // the plane in it. ProgressView(timerInterval:) with the
                    // circular style is system-animated — the ring keeps filling
                    // with the app dead and no internet, which matters because
                    // in-flight is exactly when there IS no internet.
                    if phase == .inFlight {
                        ZStack {
                            ProgressView(
                                timerInterval: progressInterval(context.state),
                                countsDown: false,
                                label: { EmptyView() },
                                currentValueLabel: { EmptyView() }
                            )
                            .progressViewStyle(.circular)
                            .tint(.green)
                            Image(systemName: context.attributes.mode.symbol)
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.green)
                        }
                    } else if phase == .landed {
                        Image(systemName: arrivalSymbol(context.attributes))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.green)
                    } else if phase == .departing {
                        Image(systemName: departureSymbol(context.attributes))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.green)
                    } else {
                        // Gate when it's known, otherwise the departure mark.
                        // The countdown lives on the TRAILING side, which has
                        // room for hours — a fixed 36pt here truncated
                        // "2:40:12" to "2:4…" with an empty right side.
                        if context.state.departureGate != nil {
                            gateBadge(context.state.departureGate)
                        } else {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .bold))
                                .padding(3)
                                .background(.green, in: Circle())
                                .foregroundStyle(.black)
                        }
                    }
                }
                .widgetURL(ArcDeepLink.url(for: context.attributes))
            } compactTrailing: {
                Group {
                    if phase == .inFlight {
                        Text.minuteCountdown(to: context.state.arrivalTime)
                            .font(.system(size: 11, weight: .bold).monospacedDigit())
                    } else if phase == .landed {
                        if let belt = context.state.baggageClaim {
                            HStack(spacing: 2) {
                                Image(systemName: "suitcase.fill")
                                    .font(.system(size: 9))
                                Text(belt)
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .foregroundStyle(.green)
                        } else if isConfirmedLanded(context.state) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.green)
                        } else {
                            Text("Soon")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.green)
                        }
                    } else if phase == .departing {
                        // Clock passed departure but takeoff is unconfirmed — a
                        // countdown says nothing here; the gate is the only
                        // number still worth the space.
                        gateBadge(context.state.departureGate)
                    } else {
                        Text.minuteCountdown(to: context.state.departureTime)
                            .font(.system(size: 11, weight: .bold).monospacedDigit())
                    }
                }
                .widgetURL(ArcDeepLink.url(for: context.attributes))
            } minimal: {
                Group {
                    if phase == .inFlight {
                        Image(systemName: context.attributes.mode.symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.green)
                    } else if phase == .landed {
                        Image(systemName: isConfirmedLanded(context.state) ? "checkmark.circle.fill" : arrivalSymbol(context.attributes))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.green)
                    } else if phase == .departing {
                        Image(systemName: departureSymbol(context.attributes))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .bold))
                            .padding(2)
                            .background(.green, in: Circle())
                            .foregroundStyle(.black)
                    }
                }
                .widgetURL(ArcDeepLink.url(for: context.attributes))
            }
        }
    }

    // MARK: - Phase

    private enum Phase { case preDeparture, departing, inFlight, landed }

    /// How long past an UNCONFIRMED departure time the widget keeps hedging
    /// ("Departing…") before assuming the plane is airborne. Stale data is
    /// usually only minutes stale — a traveler seated at the gate during an
    /// unreported extra delay must not be told they're flying. Beyond this,
    /// the offline-mid-flight interpretation wins.
    private static let departureGrace: TimeInterval = 20 * 60

    /// The "getting there" window: still scheduled and more than ~1¾ h out —
    /// roughly, before the point where a two-hours-early traveller has left.
    private func showsDirections(_ state: FlightActivityAttributes.ContentState) -> Bool {
        state.status == "scheduled"
            && Date.now < state.departureTime.addingTimeInterval(-105 * 60)
    }

    private func directionsURL(attrs: FlightActivityAttributes,
                               state: FlightActivityAttributes.ContentState) -> URL? {
        var s = "arc://directions/\(attrs.departureIATA)"
        if let t = state.departureTerminal,
           let encoded = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            s += "?t=\(encoded)"
        }
        return URL(string: s)
    }

    /// True only when a data source actually reported the landing. A phase of
    /// .landed with this false means the CLOCK passed the cached ETA while
    /// offline — the plane is probably down, but nobody has confirmed it, so
    /// the UI says "Landing soon" instead of claiming "Landed".
    private func isConfirmedLanded(_ state: FlightActivityAttributes.ContentState) -> Bool {
        state.status == "landed"
    }

    /// "airplane.departure" / "airplane.arrival" have no tram or ferry
    /// variants, so non-air legs wear their plain vehicle symbol in every
    /// phase.
    private func departureSymbol(_ attrs: FlightActivityAttributes) -> String {
        attrs.mode == .air ? "airplane.departure" : attrs.mode.symbol
    }

    private func arrivalSymbol(_ attrs: FlightActivityAttributes) -> String {
        attrs.mode == .air ? "airplane.arrival" : attrs.mode.symbol
    }

    private func effectivePhase(_ state: FlightActivityAttributes.ContentState) -> Phase {
        if state.status == "landed" { return .landed }
        // "active" must NOT bypass the clock: offline nobody flips the status
        // to landed, so the staleDate re-render at arrival has to be able to
        // conclude "landed" from the time alone — otherwise the island wears
        // its in-flight clothes forever.
        if state.status == "active" { return Date.now >= state.arrivalTime ? .landed : .inFlight }
        // Status still pre-departure but the clock passed the last known
        // departure time: nobody CONFIRMED a takeoff — the data may just be
        // stale (an unreported extra delay). Hedge with "Departing…" for a
        // grace window instead of claiming the traveler is airborne while
        // they may be sitting at the gate.
        if Date.now >= state.departureTime && Date.now < state.departureTime + Self.departureGrace,
           Date.now < state.arrivalTime {
            return .departing
        }
        if Date.now >= state.departureTime && Date.now < state.arrivalTime { return .inFlight }
        if Date.now >= state.arrivalTime { return .landed }
        return .preDeparture
    }

    // MARK: - Lock Screen

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<FlightActivityAttributes>) -> some View {
        let state = context.state
        let attrs = context.attributes
        switch effectivePhase(state) {
        case .preDeparture: preDepartureView(attrs: attrs, state: state)
        case .departing:    departingView(attrs: attrs, state: state)
        case .inFlight:     inFlightView(attrs: attrs, state: state)
        case .landed:       landedView(attrs: attrs, state: state)
        }
    }

    // ── DEPARTING (clock past departure, takeoff not confirmed) ──

    /// Mirrors the landed side's honesty pattern ("Landing soon / waiting for
    /// confirmation"): the departure time has passed but no data source
    /// reported a takeoff, so say what we actually know.
    @ViewBuilder
    private func departingView(attrs: FlightActivityAttributes, state: FlightActivityAttributes.ContentState) -> some View {
        VStack(spacing: 0) {
            headerRow(attrs: attrs, state: state)
                .padding(.bottom, 10)

            routeRow(attrs: attrs, state: state)

            HStack {
                Text(departureStatusText(state, attrs))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(departureStatusColor(state, attrs))
                    .contentTransition(.numericText())
                Spacer()
                Text(arrivalStatusText(state, attrs))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(arrivalStatusColor(state, attrs))
                    .contentTransition(.numericText())
            }
            .padding(.top, 3)
            .padding(.bottom, 14)

            insightLine(state)
                .padding(.bottom, 8)

            HStack {
                HStack(spacing: 7) {
                    Image(systemName: departureSymbol(attrs))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IntelligenceShimmerText.gradient)
                    VStack(alignment: .leading, spacing: 1) {
                        // The intelligence voice, not status-green: Arc is
                        // WAITING on confirmation, and the gradient sweeps
                        // across the text over the hedge window.
                        IntelligenceShimmerText(
                            text: "Departing…",
                            font: .system(size: 14, weight: .bold),
                            sweep: state.departureTime...state.departureTime.addingTimeInterval(Self.departureGrace))
                        Text(attrs.mode == .air ? "Waiting for takeoff confirmation" : "Waiting for departure confirmation")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                gateBadge(state.departureGate)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 17)
    }

    // ── PRE-DEPARTURE ──

    @ViewBuilder
    private func preDepartureView(attrs: FlightActivityAttributes, state: FlightActivityAttributes.ContentState) -> some View {
        VStack(spacing: 0) {
            // Row 1: Flight number + seat
            headerRow(attrs: attrs, state: state)
                .padding(.bottom, 10)

            // Row 2: SFO 10:26AM · · ✈ · · 16:45PM JFK
            routeRow(attrs: attrs, state: state)

            // Row 3: ↗ T3 · On Time          On Time
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.green)
                    if let terminal = state.departureTerminal {
                        Text("T\(terminal)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("·")
                            .foregroundStyle(.tertiary)
                    }
                    Text(departureStatusText(state, attrs))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(departureStatusColor(state, attrs))
                }
                Spacer()
                Text(arrivalStatusText(state, attrs))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(arrivalStatusColor(state, attrs))
                    .contentTransition(.numericText())
            }
            .padding(.top, 3)
            .padding(.bottom, 10)

            // Long before boarding, the useful action is getting TO the
            // airport: one tap into Apple Maps with the terminal set. The
            // pill retires ~1¾ h before departure — by then the user is en
            // route or already through security, and the space belongs to
            // boarding info again. The app resolves the coordinates; a
            // widget has no airport database.
            // Friend mode: never — directions to an airport the VIEWER isn't
            // flying from are noise (and cost a row against the height cap).
            if attrs.mode.hasAirportOperations, attrs.friendName == nil, showsDirections(state), let url = directionsURL(attrs: attrs, state: state) {
                Link(destination: url) {
                    HStack(spacing: 6) {
                        Image(systemName: "car.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Directions to \(attrs.departureIATA)\(state.departureTerminal.map { " · Terminal \($0)" } ?? "")")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .bold))
                            .opacity(0.6)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.blue.opacity(0.16), in: Capsule())
                    .foregroundStyle(.blue)
                }
                .padding(.bottom, 8)
            }

            // The smart line, when the Worker pushed one. It takes priority
            // over the security-wait row below (one contextual row, not two —
            // pre-departure is the tallest layout and the height cap is hard).
            insightLine(state)
                .padding(.bottom, 8)

            // Security wait (Waitport live data or time-of-day estimate) —
            // only meaningful while still landside, i.e. before boarding, and
            // only for the traveler themself: the security queue at the
            // FRIEND's airport is their problem, not the viewer's.
            if attrs.friendName == nil,
               (state.insight ?? "").isEmpty,
               let wait = state.securityWaitMinutes, wait > 0,
               state.status != "boarding", state.status != "gateClosed" {
                HStack(spacing: 5) {
                    Image(systemName: "figure.walk.motion")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Security wait ~\(wait) min")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.bottom, 8)
            }

            // Row 4: Boarding status + gate badge
            if state.status == "boarding" {
                // Real boarding status from API
                HStack {
                    HStack(spacing: 5) {
                        Image(systemName: "door.left.hand.open")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.green)
                        Text("Now Boarding")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.green)
                    }
                    Spacer()
                    gateBadge(state.departureGate)
                }
                .padding(.bottom, 8)
            } else if state.status == "gateClosed" {
                // Gate closed from API
                HStack {
                    HStack(spacing: 5) {
                        Image(systemName: "door.left.hand.closed")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.red)
                        Text("Gate Closed")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    gateBadge(state.departureGate)
                }
                .padding(.bottom, 8)
            } else if let boardTime = state.boardingTime, Date.now < boardTime {
                // Estimated boarding time (no API data)
                HStack {
                    HStack(spacing: 5) {
                        Image(systemName: "door.left.hand.open")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("\(Text("Boarding ").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary))\(Text(boardTime, style: .time).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary))")
                    }
                    Spacer()
                    gateBadge(state.departureGate)
                }
                .padding(.bottom, 8)
            }

            // Departs Gate countdown + gate badge. The badge shows here ONLY
            // when no row above carried it — boarding/gate-closed rows and the
            // estimated-boarding row all have their own badge, and two
            // identical yellow pills stacked reads as a rendering bug.
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .bold))
                        .padding(4)
                        .background(.green, in: Circle())
                        .foregroundStyle(.black)
                    // .relative, not the TimeDataSource countdown: the
                    // lock-screen Live Activity renderer draws the new
                    // TimeDataSource text as placeholder dashes ("–h ––m") —
                    // only the classic live styles work here.
                    HStack(spacing: 0) {
                        Text("Departs \(attrs.mode.boardingPointLabel) in ")
                            .font(.system(size: 14, weight: .medium)).foregroundStyle(.primary)
                        Text(state.departureTime, style: .relative)
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(.primary)
                    }
                }
                Spacer()
                if state.status != "boarding", state.status != "gateClosed",
                   state.boardingTime == nil || Date.now >= (state.boardingTime ?? .distantFuture) {
                    gateBadge(state.departureGate)
                }
            }
        }
        // 17pt vertical: enough air that the card doesn't read as squeezed,
        // while staying under the lock screen's hard height cap (anything
        // over just gets CLIPPED) — the row paddings above are trimmed to
        // buy the edges this room.
        .padding(.horizontal, 20)
        .padding(.vertical, 17)
    }

    // ── IN FLIGHT ──

    @ViewBuilder
    private func inFlightView(attrs: FlightActivityAttributes, state: FlightActivityAttributes.ContentState) -> some View {
        VStack(spacing: 0) {
            headerRow(attrs: attrs, state: state)
                .padding(.bottom, 8)

            routeRow(attrs: attrs, state: state)

            HStack {
                Text(departureStatusText(state, attrs))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(departureStatusColor(state, attrs))
                    .contentTransition(.numericText())
                Spacer()
                Text(arrivalStatusText(state, attrs))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(arrivalStatusColor(state, attrs))
                    .contentTransition(.numericText())
            }
            .padding(.top, 3)
            .padding(.bottom, 10)

            insightLine(state)
                .padding(.bottom, 6)

            // Flighty's glowing flight-path line, filling left→right with
            // progress — self-animating even offline (see FlightPathProgress).
            FlightPathProgress(state: state)
                .frame(height: 24)
                .padding(.bottom, 2)

            arrivalCountdown(attrs: attrs, state)
        }
        // Same edge treatment as pre-departure: 17pt vertical air, bought by
        // trimming the flight path's height rather than the outer margins.
        .padding(.horizontal, 20)
        .padding(.vertical, 17)
    }

    /// Big centered "1 hr, 20 min / UNTIL GATE ARRIVAL". `.relative` text is
    /// system-animated — it keeps counting down with the app dead and no
    /// internet, exactly the in-flight situation.
    @ViewBuilder
    private func arrivalCountdown(attrs: FlightActivityAttributes, _ state: FlightActivityAttributes.ContentState) -> some View {
        HStack {
            Spacer()
            VStack(spacing: 2) {
                if Date.now >= state.arrivalTime {
                    if isConfirmedLanded(state) {
                        Text(attrs.mode.arrivedShort)
                            .font(.system(size: 16, weight: .bold).monospacedDigit())
                            .foregroundStyle(.green)
                        Text(attrs.mode == .air ? "ARRIVED" : "AT \(attrs.arrivalIATA)")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .tracking(0.4)
                    } else {
                        // Unconfirmed = Arc is waiting: intelligence voice,
                        // sweeping over the plausible touch-down window.
                        IntelligenceShimmerText(
                            text: "\(attrs.mode.arrivingVerb.uppercased()) SOON",
                            font: .system(size: 16, weight: .bold),
                            sweep: state.arrivalTime...state.arrivalTime.addingTimeInterval(15 * 60))
                        Text("WAITING FOR CONFIRMATION")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .tracking(0.4)
                    }
                } else {
                    // .relative — the lock screen can't render the
                    // TimeDataSource countdown (placeholder dashes). The
                    // arrival staleDate re-render flips this branch before
                    // it could start counting up.
                    Text(state.arrivalTime, style: .relative)
                        .font(.system(size: 16, weight: .bold).monospacedDigit())
                        .foregroundStyle(.green)
                        .multilineTextAlignment(.center)
                    // Deliberately NO estimated/confirmed hedge at the departure
                    // side (unlike landing): departure confirmation almost always
                    // arrives after the user is already airborne and offline, so
                    // a hedge label would show on virtually every flight —
                    // permanent noise, not honesty. The flip runs off the last
                    // cached delay-adjusted estimate, refreshed every poll until
                    // connectivity was lost.
                    Text(attrs.mode == .air ? "UNTIL GATE ARRIVAL" : "UNTIL ARRIVAL")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.4)
                }
            }
            Spacer()
        }
    }

    /// Valid interval even for odd data (delayed departure recorded after
    /// scheduled arrival).
    private func progressInterval(_ state: FlightActivityAttributes.ContentState) -> ClosedRange<Date> {
        state.departureTime...max(state.arrivalTime, state.departureTime.addingTimeInterval(60))
    }

    // ── LANDED ──

    @ViewBuilder
    private func landedView(attrs: FlightActivityAttributes, state: FlightActivityAttributes.ContentState) -> some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: arrivalSymbol(attrs))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                    Text(attrs.flightNumber)
                        .font(.system(size: 14, weight: .semibold))
                }
                Spacer()
                if isConfirmedLanded(state) {
                    Text(attrs.mode.arrivedShort)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.green.opacity(0.12), in: Capsule())
                } else {
                    IntelligenceShimmerText(
                        text: "\(attrs.mode.arrivingVerb.uppercased()) SOON",
                        font: .system(size: 11, weight: .bold),
                        sweep: state.arrivalTime...state.arrivalTime.addingTimeInterval(15 * 60))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(.secondarySystemFill).opacity(0.6), in: Capsule())
                }
            }
            .padding(.bottom, 12)

            HStack {
                Text(attrs.departureIATA)
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                Image(systemName: isConfirmedLanded(state) ? "checkmark.circle.fill" : arrivalSymbol(attrs))
                    .font(.system(size: 14))
                    .foregroundStyle(.green)
                Spacer()
                Text(attrs.arrivalIATA)
                    .font(.system(size: 20, weight: .bold))
            }
            .padding(.bottom, 14)

            // Pillar 3.2: Arrival info + High-Impact Baggage Carousel Handoff
            VStack(spacing: 12) {
                HStack {
                    if let belt = state.baggageClaim {
                        HStack(spacing: 6) {
                            Image(systemName: "suitcase.cart.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                            Text("BAGGAGE BELT \(belt)")
                                .font(.system(size: 13, weight: .heavy))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.green, in: Capsule())
                        .shadow(color: .green.opacity(0.5), radius: 4)
                    } else if !attrs.mode.hasAirportOperations {
                        // Trains and ferries have no baggage carousel — the
                        // arrived verb is the whole story.
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.green)
                            Text("\(attrs.mode.arrivedVerb) at \(attrs.arrivalIATA)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        // No belt assigned yet. It used to read "Baggage
                        // Scanning…", which implied we were watching something
                        // happen — there's no such feed; we simply don't know.
                        HStack(spacing: 5) {
                            Image(systemName: "suitcase.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Text("Belt not assigned yet")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let terminal = state.arrivalTerminal {
                        Text("T\(terminal)")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    if let gate = state.arrivalGate {
                        gateBadge(gate)
                    }
                }
            }
        }
        .padding(20)
    }

    // MARK: - Components

    private func headerRow(attrs: FlightActivityAttributes, state: FlightActivityAttributes.ContentState) -> some View {
        HStack {
            HStack(spacing: 5) {
                Image(systemName: attrs.mode.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
                Text(attrs.flightNumber)
                    .font(.system(size: 14, weight: .semibold))
            }
            Spacer()
            if let friend = attrs.friendName, !friend.isEmpty {
                HStack(spacing: 5) {
                    friendAvatar(attrs, size: 18)
                    Text(friend)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                }
            } else if let seat = attrs.seat, !seat.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "carseat.right.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(seat)
                        .font(.system(size: 14, weight: .semibold))
                }
            }
        }
    }

    private func routeRow(attrs: FlightActivityAttributes, state: FlightActivityAttributes.ContentState) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(attrs.departureIATA)
                    .font(.system(size: 20, weight: .bold))
                Text(state.departureTime, style: .time)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(departureStatusColor(state, attrs))
                    .contentTransition(.numericText())
            }
            Spacer()
            HStack(spacing: 2) {
                ForEach(0..<2, id: \.self) { _ in
                    Circle().fill(.tertiary).frame(width: 2.5, height: 2.5)
                }
                Image(systemName: attrs.mode.symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                ForEach(0..<2, id: \.self) { _ in
                    Circle().fill(.tertiary).frame(width: 2.5, height: 2.5)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                Text(state.arrivalTime, style: .time)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(arrivalDelay(state) > 0 ? .orange : .secondary)
                    .contentTransition(.numericText())
                Text(attrs.arrivalIATA)
                    .font(.system(size: 20, weight: .bold))
            }
        }
    }

    /// The friend's profile picture, staged by the app in the App Group
    /// container before the activity started (widgets can't load network
    /// images). Falls back to the generic person icon when no avatar file
    /// exists — older activities, push-to-start, or users without a photo.
    @ViewBuilder
    private func friendAvatar(_ attrs: FlightActivityAttributes, size: CGFloat) -> some View {
        if let file = attrs.friendAvatarFile,
           let dir = FileManager.default.containerURL(
               forSecurityApplicationGroupIdentifier: "group.com.arc.flighttracker"),
           let image = UIImage(contentsOfFile: dir.appendingPathComponent("la-avatars/\(file)").path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.6))
                .foregroundStyle(.tertiary)
        }
    }

    /// The AI smart line: one sentence of understanding pushed by the Worker
    /// (delay trend, knock-on expectation). Sparkle wears the intelligence
    /// gradient; the text stays quiet secondary — the insight should read as
    /// understanding, not decoration.
    @ViewBuilder
    private func insightLine(_ state: FlightActivityAttributes.ContentState) -> some View {
        if let insight = state.insight, !insight.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(IntelligenceShimmerText.gradient)
                Text(insight)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.numericText())
            }
        }
    }

    /// Yellow gate badge matching Flighty's style: walking person icon + gate code
    @ViewBuilder
    private func gateBadge(_ gate: String?) -> some View {
        if let gate, !gate.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 10, weight: .bold))
                // Airport-board flip: when a push moves the gate, the badge
                // visibly rolls to the new value instead of silently differing
                // at the next glance.
                Text(gate)
                    .font(.system(size: 13, weight: .bold))
                    .contentTransition(.numericText())
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.yellow, in: Capsule())
        }
    }

    // MARK: - Helpers

    // "On Time" is a claim only a live source can make; a timetable-only leg
    // (ferry, hand-typed flight) names its source instead, in neutral —
    // the same rule the app applies everywhere else.
    private func departureStatusText(_ s: FlightActivityAttributes.ContentState,
                                     _ a: FlightActivityAttributes) -> String {
        guard a.reportsPunctuality else { return a.dataTier.qualifier ?? "Scheduled" }
        if s.delayMinutes < 0 { return "\(abs(s.delayMinutes))m Early" }
        if s.delayMinutes > 0 { return "\(s.delayMinutes)m Late" }
        return "On Time"
    }

    private func departureStatusColor(_ s: FlightActivityAttributes.ContentState,
                                      _ a: FlightActivityAttributes) -> Color {
        guard a.reportsPunctuality else { return .secondary }
        if s.delayMinutes < 0 { return .green }
        if s.delayMinutes > 0 { return .orange }
        return .green
    }

    /// Arrival has its own delay when the provider revised the arrival time
    /// independently; older pushes without the field fall back to the shared
    /// departure delay.
    private func arrivalDelay(_ s: FlightActivityAttributes.ContentState) -> Int {
        s.arrivalDelayMinutes ?? s.delayMinutes
    }

    private func arrivalStatusText(_ s: FlightActivityAttributes.ContentState,
                                   _ a: FlightActivityAttributes) -> String {
        guard a.reportsPunctuality else { return a.dataTier.qualifier ?? "Scheduled" }
        let d = arrivalDelay(s)
        if d < 0 { return "\(abs(d))m Early" }
        if d > 0 { return "\(d)m Late" }
        return "On Time"
    }

    private func arrivalStatusColor(_ s: FlightActivityAttributes.ContentState,
                                    _ a: FlightActivityAttributes) -> Color {
        guard a.reportsPunctuality else { return .secondary }
        return arrivalDelay(s) > 0 ? .orange : .green
    }
}

// MARK: - Flight Path Progress (Flighty-style sloped line)

/// The glowing "flight path" line from Flighty's in-flight Live Activity —
/// a climb ramp into a long cruise — filling left→right with flight progress.
///
/// The offline trick: a custom Path can't self-animate (WidgetKit renders it
/// once per content update), so the bright line is REVEALED by masking it
/// with a system `ProgressView(timerInterval:)` stretched to full height.
/// The system animates that timer bar's fill in the render server with no
/// app process and no network — so the reveal sweeps across the path in
/// real time even mid-flight in airplane mode. Verified empirically with the
/// app terminated (see the -laDemo hook).
struct FlightPathProgress: View {
    let state: FlightActivityAttributes.ContentState

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                flightPath(in: size)
                    .stroke(Color.secondary.opacity(0.25),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                flightPath(in: size)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .shadow(color: .green.opacity(0.7), radius: 3)
                    .mask(
                        ProgressView(
                            timerInterval: state.departureTime...max(state.arrivalTime, state.departureTime.addingTimeInterval(60)),
                            countsDown: false,
                            label: { EmptyView() },
                            currentValueLabel: { EmptyView() }
                        )
                        .progressViewStyle(.linear)
                        .tint(.white)
                        // The linear bar is only ~4pt tall; as a mask, only
                        // its alpha matters — stretch it to cover the full
                        // path height so the growing width reveals everything.
                        .scaleEffect(x: 1, y: size.height * 3, anchor: .center)
                    )
            }
        }
    }

    /// Symmetric flight profile: climb, long flat cruise, descent back to
    /// the same level it started from — takeoff and landing mirror each other.
    private func flightPath(in size: CGSize) -> Path {
        let ground = size.height * 0.90
        let cruise = size.height * 0.18
        return Path { p in
            p.move(to: CGPoint(x: 1, y: ground))
            p.addCurve(
                to: CGPoint(x: size.width * 0.24, y: cruise),
                control1: CGPoint(x: size.width * 0.10, y: ground),
                control2: CGPoint(x: size.width * 0.14, y: cruise)
            )
            p.addLine(to: CGPoint(x: size.width * 0.76, y: cruise))
            p.addCurve(
                to: CGPoint(x: size.width - 1, y: ground),
                control1: CGPoint(x: size.width * 0.86, y: cruise),
                control2: CGPoint(x: size.width * 0.90, y: ground)
            )
        }
    }
}
