import SwiftUI
import SwiftData

struct MyFlightsSheet: View {
    @Query(sort: \Flight.scheduledDeparture) private var flights: [Flight]
    var onSelect: (Flight) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("My Flights").font(ArcTheme.screenTitle)
            if flights.isEmpty {
                Text("No flights yet — tap search to add one.")
                    .font(ArcTheme.caption).foregroundStyle(.secondary)
            } else {
                ForEach(flights) { f in
                    Button { onSelect(f) } label: {
                        HStack {
                            AirlineLogoView(iata: String(f.flightNumber.prefix(2)))
                            Text("\(f.departureIATA) → \(f.arrivalIATA)").font(ArcTheme.bodyEmph)
                            Spacer()
                            Text(f.flightNumber).font(ArcTheme.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .padding(.horizontal, ArcTheme.screenPad)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FriendsSheet: View {
    var body: some View {
        VStack(alignment: .leading) {
            Text("Friends").font(ArcTheme.screenTitle)
            Text("Social is deferred — coming after core screens.")
                .font(ArcTheme.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, ArcTheme.screenPad)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PassportSheet: View {
    var body: some View {
        VStack(alignment: .leading) {
            Text("Passport").font(ArcTheme.screenTitle)
            Text("Stats coming in the Passport screen plan.")
                .font(ArcTheme.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, ArcTheme.screenPad)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
