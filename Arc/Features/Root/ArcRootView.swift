import SwiftUI
import SwiftData

struct ArcRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Flight.scheduledDeparture) private var allFlights: [Flight]

    @State private var controller = MapController()
    @State private var tab: ArcTab = .myFlights
    @State private var detent: SheetDetent = .medium
    @State private var showAdd = false
    @State private var detailFlight: Flight?

    var body: some View {
        ZStack(alignment: .bottom) {
            ArcMapView(flights: mapFlights, controller: controller)
                .ignoresSafeArea()

            BottomSheet(detent: $detent) { sheetContent }

            ArcTabBar(selection: $tab, onSearch: { showAdd = true })
                .padding(.bottom, 8)
        }
        .sheet(isPresented: $showAdd) {
            AddFlightStubSheet()
                .presentationDetents([.large])
        }
        .sheet(item: $detailFlight) { flight in
            FlightDetailStubSheet(flight: flight)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .onChange(of: allFlights.map(\.id)) { controller.fitAll(mapFlights) }
        .onChange(of: detailFlight?.id) { _, _ in
            if let f = detailFlight { controller.focus(on: f) }
        }
        .onAppear {
            DemoSeed.seedIfRequested(into: modelContext, existing: allFlights)
            controller.fitAll(mapFlights)
        }
    }

    private var mapFlights: [Flight] { allFlights.filter { $0.isUpcoming || $0.isActive } }

    @ViewBuilder private var sheetContent: some View {
        switch tab {
        case .myFlights: MyFlightsView { detailFlight = $0 }
        case .friends: FriendsSheet()
        case .passport: PassportSheet()
        }
    }
}

// Temporary detail/add stubs (real versions arrive in later plans).
struct AddFlightStubSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Add Flight").font(ArcTheme.screenTitle)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 28)).foregroundStyle(.secondary)
                }
            }
            Text("Search flow arrives in the Add-Flight plan.").font(ArcTheme.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(20)
    }
}

struct FlightDetailStubSheet: View {
    let flight: Flight
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(flight.departureIATA) → \(flight.arrivalIATA)").font(ArcTheme.sheetTitle)
            Text(flight.flightNumber).font(ArcTheme.caption).foregroundStyle(.secondary)
            Text("Full detail arrives in the Flight-Detail plan.").font(ArcTheme.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }
}
