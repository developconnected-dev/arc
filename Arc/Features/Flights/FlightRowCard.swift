import SwiftUI

/// A My Flights list card, matching Flighty: countdown block on the left,
/// airline + number + status, city pair, then the route row with arrow chips.
struct FlightRowCard: View {
    let flight: Flight

    var body: some View {
        // Countdown block rides the vertical CENTER of the row (Flighty),
        // not the top edge.
        HStack(alignment: .center, spacing: 14) {
            countdownBlock
                .frame(width: 56)

            VStack(alignment: .leading, spacing: 6) {
                // airline logo + number ........ status/date
                // airline logo + number + companions ........ status/date
                HStack(spacing: 8) {
                    AirlineLogoView(iata: flight.airlineCode, size: 20)
                    Text(flight.flightNumberSpaced)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if !companions.isEmpty {
                        companionAvatars
                    }
                    Spacer(minLength: 8)
                    if let newGate = flight.departureGate, flight.previousDepartureGate != nil, !flight.isCompleted {
                        // Same vocabulary as the detail screen's gate pills:
                        // yellow chip, black type — "gate" always looks like
                        // this in Arc, instead of a one-off warning capsule.
                        HStack(spacing: 5) {
                            Text("New gate")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 9, weight: .bold))
                                Text(newGate)
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(ArcTheme.gate, in: RoundedRectangle(cornerRadius: ArcTheme.gatePillCorner))
                        }
                        .lineLimit(1)
                    } else if flight.showsPrediction {
                        // Arc's own inference wears the smart mark — sparkles,
                        // gradient, and SmartLabel's shimmer sweep on appear.
                        SmartLabel(text: "Arc predicts +\(flight.predictedDelayMinutes)m", size: 13)
                            .lineLimit(1)
                    } else {
                        Text(flight.cardTopRight)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(flight.cardTopRightColor)
                            .lineLimit(1)
                    }
                }

                // city pair
                cityPair

                if let belt = flight.baggageClaim {
                    HStack(spacing: 5) {
                        Image(systemName: "suitcase.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Baggage Carousel • Belt \(belt)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green, in: Capsule())
                    .padding(.top, 1)
                }

                // route row
                routeRow
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
    }

    private var countdownBlock: some View {
        // Minute heartbeat + rolling digits: the countdown ticks live like the
        // widget's, instead of waiting for an unrelated re-render.
        TimelineView(.periodic(from: .now, by: 60)) { _ in
        VStack(spacing: 0) {
            if let cd = flight.countdown {
                Text(cd.value)
                    .font(.system(size: cd.value.count > 2 ? 24 : 30, weight: .heavy))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.default, value: cd.value)
                Text(cd.unit)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
            } else if flight.isActive {
                Image(systemName: "airplane")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(ArcTheme.action)
                    .symbolEffect(.pulse, options: .repeating, isActive: true)
                Text("NOW")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(ArcTheme.action)
            } else if flight.isRecentlyLanded {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(ArcTheme.onTime)
                Text("LANDED")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(ArcTheme.onTime)
            } else {
                Text("—").font(.system(size: 24, weight: .heavy)).foregroundStyle(.tertiary)
            }
        }
        }
    }

    private var cityPair: some View {
        TextHelpers.cityPair(flight.departureCity, flight.arrivalCity, size: 18)
            .lineLimit(1)
    }

    private var routeRow: some View {
        HStack(spacing: 14) {
            endpoint(arrow: "arrow.up.right", iata: flight.departureIATA, time: flight.effectiveDepTimeLocal)
            endpoint(arrow: "arrow.down.right", iata: flight.arrivalIATA, time: flight.effectiveArrTimeLocal)
            Spacer(minLength: 6)
            dataFreshnessBadge
        }
    }

    private func endpoint(arrow: String, iata: String, time: String) -> some View {
        // Flighty's chips: green when things are fine, red when late — for
        // every flight, not just imminent ones. IATA stays neutral; the
        // circle and the (effective) time carry the color.
        let tint = flight.isDelayed ? ArcTheme.late : ArcTheme.onTime
        return HStack(spacing: 6) {
            Image(systemName: arrow)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(tint, in: Circle())
            Text(iata)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.primary)
            Text(time)
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint)
        }
        // The route is the point of the row: it keeps its natural width and the
        // badge beside it yields, rather than the times wrapping mid-digit.
        .fixedSize(horizontal: true, vertical: false)
    }

    private var companions: [(user: ArcSupabase.ArcUser, seat: String?)] {
        FriendsStore.shared.companions(for: flight)
    }

    private var companionAvatars: some View {
        HStack(spacing: -6) {
            ForEach(Array(companions.prefix(3).enumerated()), id: \.offset) { _, c in
                FriendAvatar(name: c.user.display_name, size: 20, avatarURL: c.user.avatar_url)
                    .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5))
            }
        }
        .padding(.leading, 2)
    }

    private var dataFreshnessBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(flight.isDataFresh ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
                .overlay(
                    Circle()
                        .stroke(flight.isDataFresh ? Color.green : Color.clear, lineWidth: 1.5)
                        .scaleEffect(flight.isActive ? 2.0 : 1.0)
                        .opacity(flight.isActive ? 0 : 1)
                        .animation(flight.isActive ? .easeInOut(duration: 1.4).repeatForever(autoreverses: false) : .default, value: flight.isActive)
                )
            Text(flight.dataFreshnessShort)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(Color(.secondarySystemFill).opacity(0.8), in: Capsule())
    }
}
