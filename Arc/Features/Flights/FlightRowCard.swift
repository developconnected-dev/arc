import SwiftUI

/// A My Flights list card, matching Flighty: countdown block on the left,
/// airline + number + status, city pair, then the route row with arrow chips.
struct FlightRowCard: View {
    let flight: Flight

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            countdownBlock
                .frame(width: 56)

            VStack(alignment: .leading, spacing: 6) {
                // airline logo + number ........ status/date
                HStack(spacing: 8) {
                    AirlineLogoView(iata: flight.airlineCode, size: 20)
                    Text(flight.flightNumberSpaced)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(flight.cardTopRight)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(flight.cardTopRightColor)
                        .lineLimit(1)
                }

                // city pair
                cityPair

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
        VStack(spacing: 0) {
            if let cd = flight.countdown {
                Text(cd.value)
                    .font(.system(size: cd.value.count > 2 ? 24 : 30, weight: .heavy))
                    .foregroundStyle(.primary)
                Text(cd.unit)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
            } else if flight.isActive {
                Image(systemName: "airplane")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(ArcTheme.action)
                Text("NOW")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(ArcTheme.action)
            } else {
                Text("—").font(.system(size: 24, weight: .heavy)).foregroundStyle(.tertiary)
            }
        }
    }

    private var cityPair: some View {
        (Text(flight.departureCity).font(.system(size: 18, weight: .bold)).foregroundColor(.primary)
         + Text(" to ").font(.system(size: 18, weight: .regular)).foregroundColor(.secondary)
         + Text(flight.arrivalCity).font(.system(size: 18, weight: .bold)).foregroundColor(.primary))
            .lineLimit(1)
    }

    private var routeRow: some View {
        HStack(spacing: 18) {
            endpoint(arrow: "arrow.up.right", iata: flight.departureIATA, time: flight.depTimeLocal)
            endpoint(arrow: "arrow.down.right", iata: flight.arrivalIATA, time: flight.arrTimeLocal)
            Spacer(minLength: 0)
        }
    }

    private func endpoint(arrow: String, iata: String, time: String) -> some View {
        let tint = flight.accentColor
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle((flight.isSoon || flight.isActive || flight.isDelayed) ? tint : .secondary)
        }
    }
}
