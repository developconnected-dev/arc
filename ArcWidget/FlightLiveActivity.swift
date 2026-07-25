import ActivityKit
import WidgetKit
import SwiftUI

struct FlightLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FlightActivityAttributes.self) { context in
            lockScreenView(context: context)
        } dynamicIsland: { context in
            let phase = effectivePhase(context.state)
            return DynamicIsland {
                // Flighty's expanded in-flight layout: flight number top-left,
                // seat top-right, then the full-width route/path/countdown
                // stack in the bottom region.
                DynamicIslandExpandedRegion(.leading) {
                    if phase == .inFlight {
                        // The island's rounded corners curve INTO the top of the
                        // leading/trailing regions — content flush with the top
                        // edge gets visually clipped by the bezel. Nudge it down
                        // and inward, clear of the curvature.
                        HStack(spacing: 4) {
                            Image(systemName: "airplane")
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
                DynamicIslandExpandedRegion(.trailing) {
                    if phase == .inFlight {
                        if let friend = context.attributes.friendName, !friend.isEmpty {
                            HStack(spacing: 3) {
                                Image(systemName: "person.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
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
                                .foregroundStyle(context.state.delayMinutes > 0 ? .orange : .secondary)
                        }
                        .padding(.top, 4)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    // Empty — route codes live in leading/trailing (pre-flight)
                    // or the bottom stack (in-flight)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if phase == .inFlight {
                        VStack(spacing: 2) {
                            routeRow(attrs: context.attributes, state: context.state)
                            HStack {
                                Text(departureStatusText(context.state))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(departureStatusColor(context.state))
                                Spacer()
                                Text(arrivalStatusText(context.state))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(arrivalStatusColor(context.state))
                            }
                            FlightPathProgress(state: context.state)
                                .frame(height: 18)
                            arrivalCountdown(context.state)
                        }
                    } else if phase == .landed {
                        HStack(spacing: 6) {
                            Image(systemName: isConfirmedLanded(context.state) ? "checkmark.circle.fill" : "airplane.arrival")
                                .font(.system(size: 12))
                                .foregroundStyle(.green)
                            Text(isConfirmedLanded(context.state) ? "Landed" : "Landing soon")
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
                    } else {
                        HStack {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.green)
                            Text("Departs Gate in ")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            + Text(timerInterval: clamped(to: context.state.departureTime), countsDown: true)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.primary)
                            Spacer()
                            gateBadge(context.state.departureGate)
                        }
                    }
                }
            } compactLeading: {
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
                        Image(systemName: "airplane")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.green)
                    }
                } else if phase == .landed {
                    Image(systemName: "airplane.arrival")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.green)
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                            .padding(3)
                            .background(.green, in: Circle())
                            .foregroundStyle(.black)
                        // timerInterval, not .timer: clamps at 0:00 instead of
                        // counting UP once the date passes.
                        Text(timerInterval: clamped(to: context.state.departureTime), countsDown: true)
                            .font(.system(size: 11, weight: .bold).monospacedDigit())
                            .frame(width: 36)
                    }
                }
            } compactTrailing: {
                if phase == .inFlight {
                    // Clamps at 0:00 — never counts up, even if the landed
                    // re-render is late or the plane beat its cached ETA.
                    Text(timerInterval: progressInterval(context.state), countsDown: true)
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .frame(width: 52)
                        .multilineTextAlignment(.trailing)
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
                } else {
                    gateBadge(context.state.departureGate)
                }
            } minimal: {
                if phase == .inFlight {
                    Image(systemName: "airplane")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                } else if phase == .landed {
                    Image(systemName: isConfirmedLanded(context.state) ? "checkmark.circle.fill" : "airplane.arrival")
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
        }
    }

    // MARK: - Phase

    private enum Phase { case preDeparture, inFlight, landed }

    /// True only when a data source actually reported the landing. A phase of
    /// .landed with this false means the CLOCK passed the cached ETA while
    /// offline — the plane is probably down, but nobody has confirmed it, so
    /// the UI says "Landing soon" instead of claiming "Landed".
    private func isConfirmedLanded(_ state: FlightActivityAttributes.ContentState) -> Bool {
        state.status == "landed"
    }

    private func effectivePhase(_ state: FlightActivityAttributes.ContentState) -> Phase {
        if state.status == "landed" { return .landed }
        // "active" must NOT bypass the clock: offline nobody flips the status
        // to landed, so the staleDate re-render at arrival has to be able to
        // conclude "landed" from the time alone — otherwise the island wears
        // its in-flight clothes forever.
        if state.status == "active" { return Date.now >= state.arrivalTime ? .landed : .inFlight }
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
        case .inFlight:     inFlightView(attrs: attrs, state: state)
        case .landed:       landedView(attrs: attrs, state: state)
        }
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
                    Text(departureStatusText(state))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(departureStatusColor(state))
                }
                Spacer()
                Text(arrivalStatusText(state))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(arrivalStatusColor(state))
            }
            .padding(.top, 3)
            .padding(.bottom, 16)

            // Security wait (Waitport live data or time-of-day estimate) —
            // only meaningful while still landside, i.e. before boarding.
            if let wait = state.securityWaitMinutes, wait > 0,
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
                        Text("Boarding ")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        + Text(boardTime, style: .time)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    Spacer()
                    gateBadge(state.departureGate)
                }
                .padding(.bottom, 8)
            }

            // Departs Gate countdown + gate badge
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .bold))
                        .padding(4)
                        .background(.green, in: Circle())
                        .foregroundStyle(.black)
                    Text("Departs Gate in ")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                    + Text(timerInterval: clamped(to: state.departureTime), countsDown: true)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.primary)
                }
                Spacer()
                if state.boardingTime == nil || Date.now >= (state.boardingTime ?? .distantFuture) {
                    gateBadge(state.departureGate)
                }
            }
        }
        .padding(20)
    }

    // ── IN FLIGHT ──

    @ViewBuilder
    private func inFlightView(attrs: FlightActivityAttributes, state: FlightActivityAttributes.ContentState) -> some View {
        VStack(spacing: 0) {
            headerRow(attrs: attrs, state: state)
                .padding(.bottom, 10)

            routeRow(attrs: attrs, state: state)

            HStack {
                Text(departureStatusText(state))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(departureStatusColor(state))
                Spacer()
                Text(arrivalStatusText(state))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(arrivalStatusColor(state))
            }
            .padding(.top, 3)
            .padding(.bottom, 14)

            // Flighty's glowing flight-path line, filling left→right with
            // progress — self-animating even offline (see FlightPathProgress).
            FlightPathProgress(state: state)
                .frame(height: 30)
                .padding(.bottom, 4)

            arrivalCountdown(state)
        }
        .padding(20)
    }

    /// Big centered "1 hr, 20 min / UNTIL GATE ARRIVAL". `.relative` text is
    /// system-animated — it keeps counting down with the app dead and no
    /// internet, exactly the in-flight situation.
    @ViewBuilder
    private func arrivalCountdown(_ state: FlightActivityAttributes.ContentState) -> some View {
        HStack {
            Spacer()
            VStack(spacing: 2) {
                if Date.now >= state.arrivalTime {
                    Text(isConfirmedLanded(state) ? "LANDED" : "LANDING SOON")
                        .font(.system(size: 16, weight: .bold).monospacedDigit())
                        .foregroundStyle(.green)
                    Text(isConfirmedLanded(state) ? "ARRIVED" : "WAITING FOR CONFIRMATION")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.4)
                } else {
                    // timerInterval clamps at 0:00 — a .relative Text would
                    // silently start counting UP after the arrival time if
                    // the landed re-render hadn't fired yet.
                    Text(timerInterval: progressInterval(state), countsDown: true)
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
                    Text("UNTIL GATE ARRIVAL")
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

    /// Countdown interval ending at `end`, valid even if `end` already passed
    /// (the text then just sits at 0:00 instead of counting up).
    private func clamped(to end: Date) -> ClosedRange<Date> {
        let start = min(Date.now, end.addingTimeInterval(-1))
        return start...end
    }

    // ── LANDED ──

    @ViewBuilder
    private func landedView(attrs: FlightActivityAttributes, state: FlightActivityAttributes.ContentState) -> some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "airplane.arrival")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                    Text(attrs.flightNumber)
                        .font(.system(size: 14, weight: .semibold))
                }
                Spacer()
                Text(isConfirmedLanded(state) ? "LANDED" : "LANDING SOON")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.green.opacity(0.12), in: Capsule())
            }
            .padding(.bottom, 12)

            HStack {
                Text(attrs.departureIATA)
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                Image(systemName: isConfirmedLanded(state) ? "checkmark.circle.fill" : "airplane.arrival")
                    .font(.system(size: 14))
                    .foregroundStyle(.green)
                Spacer()
                Text(attrs.arrivalIATA)
                    .font(.system(size: 20, weight: .bold))
            }
            .padding(.bottom, 14)

            // Arrival info: gate badge + baggage
            HStack {
                if let belt = state.baggageClaim {
                    HStack(spacing: 5) {
                        Image(systemName: "suitcase.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("Belt \(belt)")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                if let terminal = state.arrivalTerminal {
                    HStack(spacing: 3) {
                        Text("·").foregroundStyle(.tertiary)
                        Text("T\(terminal)")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                Spacer()
                if let gate = state.arrivalGate {
                    gateBadge(gate)
                }
            }
        }
        .padding(20)
    }

    // MARK: - Components

    private func headerRow(attrs: FlightActivityAttributes, state: FlightActivityAttributes.ContentState) -> some View {
        HStack {
            HStack(spacing: 5) {
                Image(systemName: "airplane")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
                Text(attrs.flightNumber)
                    .font(.system(size: 14, weight: .semibold))
            }
            Spacer()
            if let friend = attrs.friendName, !friend.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
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
                    .foregroundStyle(.green)
            }
            Spacer()
            HStack(spacing: 2) {
                ForEach(0..<2, id: \.self) { _ in
                    Circle().fill(.tertiary).frame(width: 2.5, height: 2.5)
                }
                Image(systemName: "airplane")
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
                    .foregroundStyle(state.delayMinutes > 0 ? .orange : .secondary)
                Text(attrs.arrivalIATA)
                    .font(.system(size: 20, weight: .bold))
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
                Text(gate)
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.yellow, in: Capsule())
        }
    }

    // MARK: - Helpers

    private func departureStatusText(_ s: FlightActivityAttributes.ContentState) -> String {
        if s.delayMinutes < 0 { return "\(abs(s.delayMinutes))m Early" }
        if s.delayMinutes > 0 { return "\(s.delayMinutes)m Late" }
        return "On Time"
    }

    private func departureStatusColor(_ s: FlightActivityAttributes.ContentState) -> Color {
        if s.delayMinutes < 0 { return .green }
        if s.delayMinutes > 0 { return .orange }
        return .green
    }

    private func arrivalStatusText(_ s: FlightActivityAttributes.ContentState) -> String {
        s.delayMinutes > 0 ? "\(s.delayMinutes)m Late" : "On Time"
    }

    private func arrivalStatusColor(_ s: FlightActivityAttributes.ContentState) -> Color {
        s.delayMinutes > 0 ? .orange : .green
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
