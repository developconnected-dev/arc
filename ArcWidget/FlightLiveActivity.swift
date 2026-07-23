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
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.departureIATA)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                        Text(context.state.departureTime, style: .time)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.attributes.arrivalIATA)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                        Text(context.state.arrivalTime, style: .time)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(context.state.delayMinutes > 0 ? .orange : .secondary)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    // Empty — route codes in leading/trailing are enough
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if phase == .inFlight {
                        VStack(spacing: 4) {
                            // System-animated progress: ProgressView(timerInterval:)
                            // is one of the few things iOS itself keeps moving in a
                            // Live Activity with no app process running. The old
                            // hand-drawn version computed `pct` from Date.now at
                            // render time — frozen the moment the app was suspended.
                            liveProgressBar(context.state)

                            HStack {
                                if Date.now >= context.state.arrivalTime {
                                    Text("LANDED")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.green)
                                } else {
                                    Text(context.state.arrivalTime, style: .timer)
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.green)
                                }
                                Spacer()
                                Text(Date.now >= context.state.arrivalTime ? "ARRIVED" : "UNTIL ARRIVAL")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    } else {
                        HStack {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.green)
                            Text("Departs Gate in ")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            + Text(context.state.departureTime, style: .timer)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.primary)
                            Spacer()
                            gateBadge(context.state.departureGate)
                        }
                    }
                }
            } compactLeading: {
                // Pre-departure: arrow + countdown. In-flight: plane + dep IATA
                if phase == .inFlight {
                    HStack(spacing: 3) {
                        Image(systemName: "airplane")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.green)
                        Text(context.attributes.departureIATA)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                            .padding(3)
                            .background(.green, in: Circle())
                            .foregroundStyle(.black)
                        Text(context.state.departureTime, style: .timer)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .frame(width: 36)
                    }
                }
            } compactTrailing: {
                if phase == .inFlight {
                    if Date.now >= context.state.arrivalTime {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.green)
                    } else {
                        Text(context.state.arrivalTime, style: .timer)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .frame(width: 52)
                            .multilineTextAlignment(.trailing)
                    }
                } else {
                    gateBadge(context.state.departureGate)
                }
            } minimal: {
                if phase == .inFlight {
                    Image(systemName: "airplane")
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

    private func effectivePhase(_ state: FlightActivityAttributes.ContentState) -> Phase {
        if state.status == "landed" { return .landed }
        if state.status == "active" { return .inFlight }
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
                    + Text(state.departureTime, style: .timer)
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

            // Swooping progress arc. Honest limitation: the arc's fill is
            // `state.progress`, a frozen snapshot — without ActivityKit remote
            // push (needs a paid Apple Developer membership + APNs), a custom
            // Path can only move when OUR process pushes an update (app open,
            // the 60s updater while alive, WiFi-reconnect bursts, BG refresh
            // wakeups). The thin bar underneath is the system-animated
            // ProgressView(timerInterval:) — iOS itself keeps THAT moving with
            // no process running, so the surface is never fully frozen.
            let hasArrived = Date.now >= state.arrivalTime
            FlightProgressArc(progress: hasArrived ? 1.0 : state.progress, color: .green)
                .frame(height: 28)
            liveProgressBar(state)
                .padding(.bottom, 6)

            // Centered countdown or LANDED
            HStack {
                Spacer()
                VStack(spacing: 2) {
                    if hasArrived {
                        Text("LANDED")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.green)
                    } else {
                        Text(state.arrivalTime, style: .timer)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.green)
                            .multilineTextAlignment(.center)
                    }
                    Text(hasArrived ? "ARRIVED" : "UNTIL GATE ARRIVAL")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.4)
                }
                Spacer()
            }
        }
        .padding(20)
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
                Text("LANDED")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.green.opacity(0.12), in: Capsule())
            }
            .padding(.bottom, 12)

            HStack {
                Text(attrs.departureIATA)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.green)
                Spacer()
                Text(attrs.arrivalIATA)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
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
            if let seat = attrs.seat, !seat.isEmpty {
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
                    .font(.system(size: 20, weight: .bold, design: .rounded))
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
                    .font(.system(size: 20, weight: .bold, design: .rounded))
            }
        }
    }

    /// The one progress element iOS keeps animating with no app process
    /// running. The interval must be valid even for odd data (delayed
    /// departure recorded after scheduled arrival), hence the max().
    private func liveProgressBar(_ state: FlightActivityAttributes.ContentState) -> some View {
        let end = max(state.arrivalTime, state.departureTime.addingTimeInterval(60))
        return ProgressView(
            timerInterval: state.departureTime...end,
            countsDown: false,
            label: { EmptyView() },
            currentValueLabel: { EmptyView() }
        )
        .progressViewStyle(.linear)
        .tint(.green)
        .frame(height: 4)
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

// MARK: - Swooping Progress Arc
// Updated every 60s by BackgroundFlightUpdater via Activity.update()

struct FlightProgressArc: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                swoopPath(in: size)
                    .stroke(Color.secondary.opacity(0.15), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                swoopPath(in: size)
                    .trim(from: 0, to: max(0.005, progress))
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .shadow(color: color.opacity(0.5), radius: 3)
                    .position(swoopPoint(at: progress, in: size))
            }
        }
    }

    private func swoopPath(in size: CGSize) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 0, y: size.height * 0.85))
            p.addCurve(
                to: CGPoint(x: size.width, y: size.height * 0.85),
                control1: CGPoint(x: size.width * 0.3, y: -size.height * 0.2),
                control2: CGPoint(x: size.width * 0.7, y: -size.height * 0.2)
            )
        }
    }

    private func swoopPoint(at t: Double, in size: CGSize) -> CGPoint {
        let p0 = CGPoint(x: 0, y: size.height * 0.85)
        let p1 = CGPoint(x: size.width * 0.3, y: -size.height * 0.2)
        let p2 = CGPoint(x: size.width * 0.7, y: -size.height * 0.2)
        let p3 = CGPoint(x: size.width, y: size.height * 0.85)
        let t1 = CGFloat(t), mt = 1 - t1
        return CGPoint(
            x: mt*mt*mt*p0.x + 3*mt*mt*t1*p1.x + 3*mt*t1*t1*p2.x + t1*t1*t1*p3.x,
            y: mt*mt*mt*p0.y + 3*mt*mt*t1*p1.y + 3*mt*t1*t1*p2.y + t1*t1*t1*p3.y
        )
    }
}
