import SwiftUI

/// A My Flights list card, matching Flighty: countdown block on the left,
/// airline + number + status, city pair, then the route row with arrow chips.
///
/// Nothing on the row is heavier than semibold, and only the words that
/// carry news are coloured. The freshness pill is gone: how old the data is
/// belongs to the detail screen, not to a line the eye scans five times a day.
struct FlightRowCard: View {
    let flight: Flight
    /// A trip that isn't the user's (yet) — a friend's invitation preview.
    /// Hides the companion avatars (the inviter is named in the card around it).
    var isPreview: Bool = false

    var body: some View {
        // Countdown block rides the vertical CENTER of the row (Flighty),
        // not the top edge.
        HStack(alignment: .center, spacing: 14) {
            countdownBlock
                .frame(width: 52)

            VStack(alignment: .leading, spacing: 6) {
                // airline logo + number ........ status/date
                // airline logo + number + companions ........ status/date
                HStack(spacing: 8) {
                    TripLogoView(mode: flight.mode, iata: flight.airlineCode,
                                 logoURL: flight.operatorLogoURL, size: 20)
                    // A codeshare shows the booked number alongside the one
                    // that flies. This line is the tightest in the app, so it
                    // degrades rather than pushing the status chip off the
                    // row: full name → codes only → operating number alone.
                    ViewThatFits(in: .horizontal) {
                        numberText(flight.flightNumberWithMarketing)
                        numberText(flight.flightNumberWithMarketingShort)
                        numberText(flight.flightNumberSpaced)
                    }
                    if !isPreview, !companions.isEmpty {
                        companionAvatars
                    }
                    Spacer(minLength: 8)
                    // A gate change is the news only while nothing louder is
                    // going on: once the flight is delayed, boarding or in the
                    // air, that state owns the corner (the change stays on the
                    // detail screen). Before this the chip hid "Delayed 45m"
                    // and "In Air" for the rest of the leg's life.
                    if let newGate = flight.departureGate, flight.previousDepartureGate != nil,
                       flight.isUpcoming, !flight.isBoarding, !flight.isDelayed,
                       !flight.showsPrediction, !flight.isDepartureUnconfirmed {
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
                        topRight.lineLimit(1)
                    }
                }

                // city pair
                cityPair

                if flight.showsBaggageBelt, let belt = flight.baggageClaim {
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
        // Pin the row to the leading edge even when content wants more width
        // than it has — an overflowing stack otherwise gets CENTERED, which
        // shifted each row left by a different amount (whichever badge/chip
        // happened to be widest) and broke the column alignment.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
    }

    private var countdownBlock: some View {
        // Minute heartbeat + rolling digits: the countdown ticks live like the
        // widget's, instead of waiting for an unrelated re-render.
        TimelineView(.periodic(from: .now, by: 60)) { _ in
        VStack(spacing: 0) {
            if let cd = flight.countdown {
                Text(cd.value)
                    // Monospaced digits: "24", "34" and "46" render the same
                    // width, so the centered numbers form a true column.
                    .font(.system(size: cd.value.count > 2 ? 24 : 30, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.default, value: cd.value)
                Text(cd.unit)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
            } else if flight.isActive {
                Image(systemName: flight.mode.symbol)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(ArcTheme.action)
                    .symbolEffect(.pulse, options: .repeating, isActive: true)
                Text("NOW")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ArcTheme.action)
            } else if flight.isRecentlyLanded {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(ArcTheme.onTime)
                Text("LANDED")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ArcTheme.onTime)
            } else {
                Text("—").font(.system(size: 24, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
        }
    }

    private var cityPair: some View {
        TextHelpers.cityPair(flight.departureCity, flight.arrivalCity, size: 18, weight: .semibold)
            .lineLimit(1)
    }

    private var routeRow: some View {
        HStack(spacing: 8) {
            endpoint(arrow: "arrow.up.right", iata: flight.departureIATA, time: flight.effectiveDepTimeLocal)
            endpoint(arrow: "arrow.down.right", iata: flight.arrivalIATA, time: flight.effectiveArrTimeLocal)
            Spacer(minLength: 2)
        }
    }

    /// "Departs On Time": the verb in quiet grey, the punctuality in its
    /// colour. Only the word that carries news is emphasised — a date, or a
    /// state nobody has confirmed, reads as plain text.
    private var topRight: Text {
        let text = flight.cardTopRight
        let verb = "Departs "
        let weight: Font.Weight = flight.cardTopRightIsQuiet ? .regular : .semibold
        let status = Text(text.hasPrefix(verb) ? String(text.dropFirst(verb.count)) : text)
            .font(.system(size: 14, weight: weight))
            .foregroundColor(flight.cardTopRightColor)
        guard text.hasPrefix(verb) else { return status }
        return Text(verb).font(.system(size: 14)).foregroundColor(.secondary) + status
    }

    private func numberText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func endpoint(arrow: String, iata: String, time: String) -> some View {
        // Flighty's chips: green when things are fine, red when late — for
        // every flight, not just imminent ones. IATA stays neutral; the
        // circle and the (effective) time carry the color.
        //
        // Green is a claim, though, and a ferry timetable makes no such claim.
        // Colouring a sailing green says the operator confirmed it is running to
        // time when nobody published anything of the sort, so a timetable-only
        // leg gets a neutral chip and lets its times speak for themselves.
        let tint = flight.isDelayed ? ArcTheme.late
            : (flight.reportsPunctuality ? ArcTheme.onTime : Color(.secondaryLabel))
        return HStack(spacing: 4) {
            Image(systemName: arrow)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(tint, in: Circle())
            Text(iata)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
            Text(time)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint)
        }
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

}
