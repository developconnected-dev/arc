import SwiftUI
import SwiftData

/// Flighty-parity Passport: passport card, delay card, most-flown-aircraft card,
/// and the sortable past-flights list. Renders over the shared map (globe).
struct PassportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayScale) private var displayScale
    @Query(sort: \Flight.scheduledDeparture, order: .reverse) private var allFlights: [Flight]
    @State private var scope: Scope = .allTime
    @State private var sort: SortKey = .date
    @State private var showSettings = false
    @State private var statsMode: StatsMode?
    var onSelect: (Flight) -> Void = { _ in }

    enum Scope: Hashable { case allTime, year(Int) }
    enum SortKey: String, CaseIterable { case date = "Date", from = "From", to = "To", airline = "Airline", aircraft = "Aircraft" }

    private var years: [Int] {
        Set(completed.map { Calendar.current.component(.year, from: $0.scheduledDeparture) }).sorted(by: >)
    }
    /// Every flight that's happened (or was meant to) — landed, cancelled, or
    /// diverted. A cancelled flight is neither upcoming nor landed, so without
    /// this it would vanish from the app entirely once marked cancelled.
    /// `PassportStats` filters back down to `.landed` internally, so distance/
    /// time/aircraft stats stay correct even though the history list is wider.
    private var completed: [Flight] { allFlights.filter { $0.isCompleted } }
    private var scoped: [Flight] {
        switch scope {
        case .allTime: completed
        case .year(let y): completed.filter { Calendar.current.component(.year, from: $0.scheduledDeparture) == y }
        }
    }
    private var stats: PassportStats { PassportStats(scoped) }

    private var sortedPast: [Flight] {
        switch sort {
        case .date: scoped
        case .from: scoped.sorted { $0.departureIATA < $1.departureIATA }
        case .to: scoped.sorted { $0.arrivalIATA < $1.arrivalIATA }
        case .airline: scoped.sorted { $0.airlineCode < $1.airlineCode }
        case .aircraft: scoped.sorted { ($0.aircraftShort ?? "") < ($1.aircraftShort ?? "") }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 20).padding(.top, 4)
            scopeChips.padding(.horizontal, 20).padding(.vertical, 10)
            ScrollViewReader { proxy in
                // List, not ScrollView+VStack — swipeActions only work on List
                // rows, and each past flight needs its own independent swipe
                // (see delete(_:) below). Cards above stay as plain, non-swipeable
                // rows with the List's own chrome stripped out.
                List {
                    listRow(bottom: 7) { passportCard }
                    if stats.delayMinutesLost > 0 { listRow(bottom: 7) { delayCard } }
                    listRow(bottom: 12) { pastFlightsHeader }

                    ForEach(sortedPast) { f in
                        Button { onSelect(f) } label: { pastRow(f) }
                            .buttonStyle(.plain)
                            .id(f.flightNumber)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(Color(.separator))
                                    .frame(height: 1.0 / displayScale)
                                    .frame(maxWidth: .infinity)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { delete(f) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }

                    Color.clear.frame(height: 1).id("bottom")
                        .listRowSeparator(.hidden).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                    Color.clear.frame(height: 140)   // clear the floating pill
                        .listRowSeparator(.hidden).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .onAppear {
                    let args = ProcessInfo.processInfo.arguments
                    if let i = args.firstIndex(of: "-passportScrollTo"), i + 1 < args.count {
                        let target = args[i + 1]
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                            withAnimation { proxy.scrollTo(target, anchor: .top) }
                        }
                    } else if ProcessInfo.processInfo.arguments.contains("-passportBottom") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(item: $statsMode) { mode in StatsDetailView(flights: scoped, mode: mode) }
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-openStats"), i + 1 < args.count {
                statsMode = StatsMode(rawValue: args[i + 1])
            }
        }
    }

    /// A non-swipeable List row with the standard 16pt side padding + spacing
    /// used throughout this screen, chrome stripped so it reads as plain content.
    private func listRow<V: View>(bottom: CGFloat, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: bottom, trailing: 16))
    }

    private func delete(_ flight: Flight) {
        Task { await Flight.delete(flight, from: modelContext) }
    }

    private var passportShareText: String {
        "My Arc passport: \(stats.flights) flights · \(stats.distanceFormatted) · \(stats.airports) airports · \(stats.flightTimeFormatted) in the air"
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Passport").font(ArcTheme.screenTitle)
            Spacer()
            if stats.flights > 0 {
                ShareLink(item: passportShareText) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary).frame(width: 36, height: 36)
                        .background(Color(.secondarySystemFill), in: Circle())
                }
            }
            Button { showSettings = true } label: {
                ProfileButtonIcon(size: 34)
            }.buttonStyle(.plain)
        }
    }

    private var scopeChips: some View {
        HStack(spacing: 8) {
            chip("All-Time", active: scope == .allTime) { scope = .allTime }
            ForEach(years, id: \.self) { y in
                chip(String(y), active: scope == .year(y)) { scope = .year(y) }
            }
            Spacer()
        }
    }
    private func chip(_ t: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(active ? .primary : .secondary)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(active ? AnyShapeStyle(Color(.secondarySystemFill)) : AnyShapeStyle(.clear), in: Capsule())
        }.buttonStyle(.plain)
    }

    // MARK: Cards

    private var passportCard: some View {
        gradientCard(colors: [Color(red: 0.16, green: 0.19, blue: 0.45), Color(red: 0.10, green: 0.28, blue: 0.62)]) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(scope == .allTime ? "ALL-TIME ARC PASSPORT" : "ARC PASSPORT")
                        .font(.system(size: 17, weight: .heavy)).foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "square.and.arrow.up").foregroundStyle(.white.opacity(0.8))
                }
                Text("PASSPORT · PASS · PASAPORTE")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                HStack(alignment: .top, spacing: 20) {
                    statBlock("FLIGHTS", "\(stats.flights)", sub: "\(stats.longHaul) Long Haul")
                    statBlock("DISTANCE", stats.distanceFormatted, sub: stats.aroundWorld)
                }
                HStack(alignment: .top, spacing: 20) {
                    statBlock("FLIGHT TIME", stats.flightTimeFormatted, sub: nil)
                    statBlock("AIRPORTS", "\(stats.airports)", sub: nil)
                    statBlock("AIRLINES", "\(stats.airlines)", sub: nil)
                }
                pillButton("All Flight Stats", mode: .flight)
            }
        }
    }

    private var delayCard: some View {
        gradientCard(colors: [Color(red: 0.45, green: 0.09, blue: 0.11), Color(red: 0.62, green: 0.12, blue: 0.14)]) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(stats.delayMinutesLost)").font(.system(size: 52, weight: .heavy)).foregroundStyle(.white)
                Text("minutes lost from delays").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                Text("Delayed flights averaged \(stats.avgDelay)m late")
                    .font(.system(size: 14)).foregroundStyle(.white.opacity(0.75))
                pillButton("All Delay Stats", mode: .delay)
            }
        }
    }

    /// Title + sort chips + count row. The past-flight rows themselves live
    /// directly in `body` (not nested in here) so each can be an independent,
    /// swipeable List row — a `ForEach` buried inside this VStack would render
    /// as one opaque row from the List's perspective, with no per-row swipe.
    private var pastFlightsHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Past Flights").font(.system(size: 22, weight: .bold))
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(SortKey.allCases, id: \.self) { key in
                        Button { sort = key } label: {
                            HStack(spacing: 3) {
                                Text(key.rawValue).font(.system(size: 15, weight: sort == key ? .bold : .regular))
                                if sort == key { Image(systemName: "arrow.down").font(.system(size: 11, weight: .bold)) }
                            }
                            .foregroundStyle(sort == key ? .primary : .secondary)
                        }.buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Text("\(scopeLabel)").font(.system(size: 15, weight: .bold))
                Spacer()
                Text("\(scoped.count) FLIGHTS").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    private var scopeLabel: String {
        switch scope { case .allTime: "All-Time"; case .year(let y): String(y) }
    }

    private func pastRow(_ f: Flight) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AirlineLogoView(iata: f.airlineCode, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(f.flightNumberSpaced).font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                    Text("\(f.departureIATA) → \(f.arrivalIATA)").font(.system(size: 14)).foregroundStyle(.tertiary)
                    Spacer()
                    Text(dateText(f)).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                TextHelpers.cityPair(f.departureCity, f.arrivalCity, size: 17)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if f.status == .cancelled { statusTag("Cancelled", color: ArcTheme.late) }
                    if f.status == .diverted { statusTag("Diverted", color: .orange) }
                    tag(f.durationFormatted)
                    if let a = f.aircraftShort { tag(a) }
                    if let r = f.aircraftRegistration { tag(r) }
                }
            }
        }
        .padding(.vertical, 10)
    }

    private func tag(_ t: String) -> some View {
        Text(t).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .overlay(Capsule().stroke(Color(.separator), lineWidth: 1))
    }

    private func statusTag(_ t: String, color: Color) -> some View {
        Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func dateText(_ f: Flight) -> String {
        let d = DateFormatter(); d.locale = Locale(identifier: "en_GB"); d.dateFormat = "d MMM yyyy"
        d.timeZone = f.depTimeZone   // the flight's local date, not the device's
        return d.string(from: f.scheduledDeparture)
    }

    // MARK: helpers

    private func statBlock(_ label: String, _ value: String, sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            Text(value).font(.system(size: 26, weight: .heavy)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
            if let sub { Text(sub).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pillButton(_ title: String, mode: StatsMode, dark: Bool = false) -> some View {
        Button { statsMode = mode } label: {
            HStack {
                Text(title).font(.system(size: 16, weight: .semibold))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(dark ? Color(red: 0.1, green: 0.2, blue: 0.4) : .white)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background((dark ? Color.white.opacity(0.5) : Color.white.opacity(0.15)), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func gradientCard<Content: View>(colors: [Color], @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}
