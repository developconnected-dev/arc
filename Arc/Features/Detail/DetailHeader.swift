import SwiftUI

/// The top of a flight's detail — what the tapped row glides into. Three
/// text sizes (28 / 15 / 13), one colour (the status pill), an icon per
/// fact. The header owns times, airports, terminals, gates, duration and
/// date; nothing below it repeats them.
struct DetailHeader: View {
    let flight: Flight
    var isOwnFlight: Bool = true
    var onShowAtGate: ((Flight) -> Void)? = nil
    var onShowAirport: ((Flight) -> Void)? = nil
    var onAirport: ((String) -> Void)? = nil

    private var model: DetailHeaderModel { DetailHeaderModel(flight: flight) }

    var body: some View {
        let m = model
        VStack(alignment: .leading, spacing: 16) {
            topLine(m)
            strip(m)
            HStack(spacing: 8) {
                tile(m.departure, isArrival: false)
                tile(m.arrival, isArrival: true)
            }
            actions
        }
        .padding(.bottom, 2)
    }

    // MARK: Top line

    private func topLine(_ m: DetailHeaderModel) -> some View {
        HStack(spacing: 8) {
            TripLogoView(mode: flight.mode, iata: flight.airlineCode,
                         logoURL: flight.operatorLogoURL, size: 20)
            Text(m.number).font(.system(size: 15, weight: .medium))
            Text("· \(m.date)").font(.system(size: 15)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(m.pill.text)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(m.pill.color)
                .padding(.horizontal, 13).padding(.vertical, 7)
                .background(m.pill.color.opacity(0.14), in: Capsule())
                .lineLimit(1)
        }
    }

    // MARK: Route strip

    private func strip(_ m: DetailHeaderModel) -> some View {
        HStack(alignment: .top, spacing: 12) {
            code(m.departure, alignment: .leading, arrow: "arrow.up.right")
            VStack(spacing: 4) {
                ZStack {
                    Rectangle().fill(Color(.separator)).frame(height: 1)
                    Image(systemName: flight.mode.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .background(Color.clear)
                }
                Text(m.duration).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            code(m.arrival, alignment: .trailing, arrow: "arrow.down.right")
        }
    }

    private func code(_ e: DetailHeaderModel.Endpoint, alignment: HorizontalAlignment, arrow: String) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Button { onAirport?(e.iata) } label: {
                Text(e.iata).font(.system(size: 28, weight: .semibold)).lineLimit(1)
            }
            .buttonStyle(.plain)
            .disabled(onAirport == nil)
            Text(e.city).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 5) {
                if let terminal = e.terminal, !terminal.isEmpty {
                    smallPill("T\(terminal)")
                }
                if flight.mode == .air || e.gate != nil {
                    gatePill(e, arrow: arrow)
                }
                if let belt = e.belt {
                    smallPill("Belt \(belt)", icon: "suitcase.rolling")
                }
            }
            .padding(.top, 5)
        }
    }

    private func smallPill(_ text: String, icon: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
            Text(text).font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: ArcTheme.gatePillCorner))
    }

    @ViewBuilder private func gatePill(_ e: DetailHeaderModel.Endpoint, arrow: String) -> some View {
        let isArrival = arrow == "arrow.down.right"
        let hasTail = flight.aircraftICAO24?.isEmpty == false || flight.aircraftRegistration?.isEmpty == false
        let opensMap = isOwnFlight && onShowAtGate != nil && flight.mode == .air
            && e.gate?.isEmpty == false && flight.hasRoute
            && ((isArrival && flight.status == .landed && flight.isRecentlyLanded)
                || (!isArrival && flight.isUpcoming && hasTail))
        let pill = HStack(spacing: 3) {
            Image(systemName: arrow).font(.system(size: 10, weight: .bold))
            Text(e.gate ?? "--").font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(e.gatePending ? Color(.secondaryLabel) : .black)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(e.gatePending ? Color(.tertiarySystemFill) : ArcTheme.gate,
                    in: RoundedRectangle(cornerRadius: ArcTheme.gatePillCorner))
        if opensMap {
            Button { onShowAtGate?(flight) } label: { pill }.buttonStyle(.plain)
                .accessibilityLabel("Show plane at gate \(e.gate ?? "")")
        } else {
            pill
        }
    }

    // MARK: Tiles

    private func tile(_ e: DetailHeaderModel.Endpoint, isArrival: Bool) -> some View {
        let alignment: HorizontalAlignment = isArrival ? .trailing : .leading
        return VStack(alignment: alignment, spacing: 6) {
            HStack(spacing: 5) {
                if !isArrival {
                    Image(systemName: departureGlyph).font(.system(size: 14, weight: .medium))
                    Text("Departs").font(.system(size: 13))
                    Text(e.iata).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                } else {
                    Text(e.iata).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                    Text("Arrives").font(.system(size: 13))
                    Image(systemName: arrivalGlyph).font(.system(size: 14, weight: .medium))
                }
            }
            .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if isArrival, let was = e.scheduledIfMoved {
                    Text(was).font(.system(size: 15)).strikethrough().foregroundStyle(.secondary)
                }
                Text(e.time)
                    .font(.system(size: 28, weight: .semibold).monospacedDigit())
                    .foregroundStyle(e.tint)
                    .contentTransition(.numericText())
                if !isArrival, let was = e.scheduledIfMoved {
                    Text(was).font(.system(size: 15)).strikethrough().foregroundStyle(.secondary)
                }
            }
            Text(e.context).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: isArrival ? .trailing : .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: ArcTheme.cardCorner))
    }

    private var departureGlyph: String { flight.mode == .air ? "airplane.departure" : flight.mode.symbol }
    private var arrivalGlyph: String { flight.mode == .air ? "airplane.arrival" : flight.mode.symbol }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        let hasTail = flight.aircraftICAO24?.isEmpty == false || flight.aircraftRegistration?.isEmpty == false
        let showsMap = onShowAirport != nil && flight.mode == .air && flight.hasRoute
        let showsPlane = onShowAtGate != nil && flight.mode == .air && flight.hasRoute
            && ((flight.isUpcoming && hasTail)
                || (flight.status == .landed && flight.isRecentlyLanded && flight.arrivalGate != nil))
        if showsMap || showsPlane {
            HStack(spacing: 8) {
                if showsMap {
                    actionButton("Terminal map", icon: "map") { onShowAirport?(flight) }
                }
                if showsPlane {
                    actionButton(flight.isRecentlyLanded ? "Arrival gate" : "My plane", icon: "airplane") { onShowAtGate?(flight) }
                }
            }
        }
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 15, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

/// What a detail opened from: the user's own row, or a friend's row in
/// the feed. Decides the key the row reported under and the row layout the
/// travelling copy fades out of.
enum HeroSource {
    case own(Flight)
    case friend(FriendFlightGroup, Flight)
    /// A trip a friend invited the user on, previewed from its card in My
    /// Trips before it is accepted.
    case invite(FriendsStore.TripInviteItem, Flight)

    var flight: Flight {
        switch self {
        case .own(let f), .friend(_, let f), .invite(_, let f): f
        }
    }
    var key: String {
        switch self {
        case .own(let f): f.id.uuidString
        case .friend(let item, _): item.id
        case .invite(let item, _): item.id
        }
    }
    var isOwn: Bool { if case .own = self { true } else { false } }
}

/// The copy of the card that travels between the list and the detail: the
/// row's layout fading into the header's as the frame grows.
struct HeroCard: View {
    let source: HeroSource
    let progress: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                switch source {
                case .own(let flight): FlightRowCard(flight: flight)
                case .friend(let item, _): FriendFlightRow(group: item)
                case .invite(let item, _):
                    TripInviteCard(item: item, onOpen: { _ in }, onAccept: {}, onDecline: {})
                }
            }
            .opacity(1 - progress)
            DetailHeader(flight: source.flight, isOwnFlight: source.isOwn)
                .opacity(progress)
        }
    }
}
