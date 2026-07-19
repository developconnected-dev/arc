import SwiftUI
import SwiftData

struct ArcRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Flight.scheduledDeparture) private var allFlights: [Flight]

    @State private var controller = MapController()
    @State private var tab: ArcTab = ProcessInfo.processInfo.arguments.contains("-tabPassport") ? .passport
        : ProcessInfo.processInfo.arguments.contains("-tabFriends") ? .friends : .myFlights
    @State private var detent: SheetDetent = .medium
    @State private var showAdd = false
    @State private var detailFlight: Flight?
    @State private var detailDetent: PresentationDetent = .large
    @State private var pendingOpenDetail = ProcessInfo.processInfo.arguments.contains("-openDetail")

    /// Test hooks for headless screenshots.
    private var addInitialQuery: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-addQuery"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ArcMapView(flights: mapFlights, controller: controller)
                .ignoresSafeArea()

            if let active = activeFlight, active.liveSpeed != nil || active.liveAltitude != nil {
                speedAltPill(active).frame(maxHeight: .infinity, alignment: .top).padding(.top, 6)
            }

            MapControls(controller: controller) { controller.fitAll(mapFlights) }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.trailing, 12).padding(.top, 8)

            BottomSheet(detent: $detent) { sheetContent }

            ArcTabBar(selection: $tab, onSearch: { showAdd = true })
                .padding(.bottom, 8)
        }
        .sheet(isPresented: $showAdd) {
            AddFlightView(initialQuery: addInitialQuery)
                .presentationDetents([.large])
        }
        .sheet(item: $detailFlight) { flight in
            FlightDetailView(flight: flight)
                .presentationDetents([.medium, .large], selection: $detailDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .onChange(of: allFlights.map(\.id)) { _, _ in
            updateCameraForTab(tab)
            openDetailIfPending()
            bootstrapTrackingAndWidgets()
        }
        .onChange(of: tab) { _, newTab in updateCameraForTab(newTab) }
        .onChange(of: detailFlight?.id) { _, _ in
            if let f = detailFlight { controller.focus(on: f) }
        }
        .onAppear {
            DemoSeed.seedIfRequested(into: modelContext, existing: allFlights)
            updateCameraForTab(tab)
            openDetailIfPending()
            bootstrapTrackingAndWidgets()
            if ProcessInfo.processInfo.arguments.contains("-openAdd") { showAdd = true }
        }
    }

    private var mapFlights: [Flight] {
        switch tab {
        case .passport: return allFlights.filter { $0.departureLat != 0 && $0.arrivalLat != 0 }
        default: return allFlights.filter { $0.isUpcoming || $0.isActive }
        }
    }

    private func updateCameraForTab(_ t: ArcTab) {
        if t == .passport {
            controller.style = .hybrid
            controller.fitAll(mapFlights, padding: 2.2)
        } else {
            controller.style = .standard
            controller.fitAll(mapFlights)
        }
    }

    private func bootstrapTrackingAndWidgets() {
        FlightTracker.shared.startTracking(flights: allFlights, modelContext: modelContext)
        WidgetSync.sync(flights: allFlights)
    }

    private var activeFlight: Flight? { allFlights.first { $0.isActive } }

    private func speedAltPill(_ f: Flight) -> some View {
        HStack(spacing: 14) {
            if let s = f.liveSpeed {
                Label("\(Int(s * 3.6)) km/h", systemImage: "speedometer")
                    .labelStyle(.titleAndIcon)
            }
            if let a = f.liveAltitude {
                Label(altString(a), systemImage: "arrow.up.to.line")
                    .labelStyle(.titleAndIcon)
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color(.separator).opacity(0.4), lineWidth: 0.5))
    }

    private func altString(_ meters: Double) -> String {
        let f = NumberFormatter(); f.groupingSeparator = "'"; f.numberStyle = .decimal; f.maximumFractionDigits = 0
        return (f.string(from: NSNumber(value: meters)) ?? "\(Int(meters))") + " m"
    }

    private func openDetailIfPending() {
        guard pendingOpenDetail, detailFlight == nil, !allFlights.isEmpty else { return }
        detailFlight = allFlights.first(where: { $0.isActive }) ?? allFlights.first
        pendingOpenDetail = false
    }

    @ViewBuilder private var sheetContent: some View {
        switch tab {
        case .myFlights: MyFlightsView { detailFlight = $0 }
        case .friends: FriendsSheet()
        case .passport: PassportView { detailFlight = $0 }
        }
    }
}


