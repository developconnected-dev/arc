import SwiftUI

/// A memory of the journey, using recorded facts only. In particular, a
/// timetable's duration is never presented as time actually spent travelling.
struct JourneyRecap {
    let destination: String
    let route: String
    let date: String
    let travelTime: String?
    let shareText: String

    init(_ flight: Flight) {
        destination = flight.arrivalCity.isEmpty ? flight.arrivalIATA : flight.arrivalCity
        let origin = flight.departureCity.isEmpty ? flight.departureIATA : flight.departureCity
        route = "\(origin) → \(destination)"
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.timeZone = flight.depTimeZone
        date = formatter.string(from: flight.scheduledDeparture)
        if let departure = flight.actualDeparture, let arrival = flight.actualArrival,
           arrival > departure {
            travelTime = FlightClock.delayText(Int(arrival.timeIntervalSince(departure) / 60))
        } else {
            travelTime = nil
        }
        // Only public journey facts belong in an explicitly shared recap.
        // Booking codes, seats, notes and companion identities stay private.
        shareText = "\(route)\n\(flight.flightNumberSpaced) · \(date)"
            + (travelTime.map { "\n\($0) travelling" } ?? "")
            + "\nMy travels with Arc"
    }
}

struct JourneyRecapCard: View {
    let flight: Flight
    var onOpen: (() -> Void)? = nil

    var body: some View {
        let recap = JourneyRecap(flight)
        VStack(alignment: .leading, spacing: 16) {
            Label("A journey to remember", systemImage: "book.closed")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ArcTheme.brand)
            VStack(alignment: .leading, spacing: 6) {
                Text(recap.destination)
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                Text(recap.route)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(recap.date)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            if let time = recap.travelTime {
                Label("\(time) travelling", systemImage: "clock")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { actions(recap) }
                VStack(alignment: .leading, spacing: 12) { actions(recap) }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(ArcTheme.brand.opacity(0.16), lineWidth: 1)
        }
    }

    @ViewBuilder private func actions(_ recap: JourneyRecap) -> some View {
        if let onOpen {
            Button(action: onOpen) {
                Label("View journey", systemImage: "arrow.up.right")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(ArcTheme.brand)
        }
        ShareLink(item: recap.shareText) {
            Label("Share recap", systemImage: "square.and.arrow.up")
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(ArcTheme.brand)
    }
}
