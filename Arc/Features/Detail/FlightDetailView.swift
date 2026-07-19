import SwiftUI
import SwiftData

/// Flighty-parity flight detail, presented as a bottom sheet over the shared map.
struct FlightDetailView: View {
    @Bindable var flight: Flight
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var editing: EditField?
    @State private var editText = ""

    enum EditField: String, Identifiable { case bookingCode, seat, notes; var id: String { rawValue } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 18) {
                    header
                    statusBanner
                    endpointsCard
                    bookingSeatRow
                    GoodToKnowSection(flight: flight)
                    WheresMyPlaneSection(flight: flight).id("plane")
                    DetailedTimetableSection(flight: flight)
                    AirlineInfoSection(flight: flight)
                    RouteHistorySection(flight: flight)
                    NotesSection(flight: flight) { editField(.notes) }
                    actionBar
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .onAppear {
                let args = ProcessInfo.processInfo.arguments
                let target = args.contains("-detailBottom") ? "bottom" : args.contains("-detailPlane") ? "plane" : nil
                if let target {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        withAnimation { proxy.scrollTo(target, anchor: target == "plane" ? .top : .bottom) }
                    }
                }
            }
        }
        .presentationDragIndicator(.visible)
        .alert(editTitle, isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField(editTitle, text: $editText)
            Button("Cancel", role: .cancel) { editing = nil }
            Button("Save") { saveEdit() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            AirlineLogoView(iata: flight.airlineCode, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(flight.flightNumberSpaced) • \(flight.headerDateText)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                cityPair
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(Color(.secondarySystemFill), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var cityPair: some View {
        (Text(flight.departureCity).font(.system(size: 24, weight: .bold)).foregroundColor(.primary)
         + Text(" to ").font(.system(size: 24, weight: .regular)).foregroundColor(.secondary)
         + Text(flight.arrivalCity).font(.system(size: 24, weight: .bold)).foregroundColor(.primary))
            .lineLimit(2)
    }

    // MARK: Status banner

    private var statusBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(flight.bannerHeadline)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(flight.bannerColor)
            if let inbound = inboundLine {
                HStack(spacing: 4) {
                    Text(inbound).font(.system(size: 14)).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(flight.bannerColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private var inboundLine: String? {
        if flight.isActive { return "Live tracking active" }
        if flight.inboundDelayMinutes > 0 { return "Inbound aircraft is \(flight.inboundDelayMinutes)m late" }
        if flight.aircraftRegistration != nil { return "Inbound aircraft has arrived" }
        return "Checking inbound aircraft"
    }

    // MARK: Endpoints

    private var endpointsCard: some View {
        VStack(spacing: 0) {
            endpoint(isArrival: false)
            HStack(spacing: 8) {
                Image(systemName: "clock").font(.system(size: 12)).foregroundStyle(.tertiary)
                Text("\(flight.durationFormatted) • \(flight.distanceFormatted)")
                    .font(.system(size: 13)).foregroundStyle(.tertiary)
                Rectangle().fill(Color(.separator)).frame(height: 0.5)
            }
            .padding(.vertical, 10)
            endpoint(isArrival: true)
        }
    }

    private func endpoint(isArrival: Bool) -> some View {
        let iata = isArrival ? flight.arrivalIATA : flight.departureIATA
        let name = isArrival ? flight.arrivalAirportName : flight.departureAirportName
        let time = isArrival ? flight.effectiveArrTimeLocal : flight.effectiveDepTimeLocal
        let schedTime = isArrival ? flight.arrTimeLocal : flight.depTimeLocal
        let changed = isArrival ? flight.arrivalChanged : flight.departureChanged
        let statusText = isArrival ? flight.arrivalStatusText : flight.departureStatusText
        let relText = isArrival ? flight.arrivalRelText : flight.departureRelText
        let gate = isArrival ? flight.arrivalGate : flight.departureGate
        let terminal = isArrival ? flight.arrivalTerminal : flight.departureTerminal
        let arrow = isArrival ? "arrow.down.right" : "arrow.up.right"

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: arrow).font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(.systemBackground))
                    .frame(width: 18, height: 18).background(Color.primary, in: Circle())
                Text(iata).font(.system(size: 15, weight: .bold))
                Text("• \(name)").font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(time).font(.system(size: 40, weight: .regular))
                            .foregroundStyle(flight.bannerColor)
                        if changed {
                            Text(schedTime).font(.system(size: 17))
                                .strikethrough().foregroundStyle(.secondary)
                        }
                    }
                    Text("\(statusText) • \(relText)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(flight.bannerColor)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    GatePill(arrow: arrow, gate: gate ?? "--")
                    if let terminal { Text("Terminal \(terminal)").font(.system(size: 13)).foregroundStyle(.secondary) }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Booking / Seat

    private var bookingSeatRow: some View {
        HStack(spacing: 12) {
            editCard(title: "Booking Code", value: flight.bookingCode, icon: "ticket") { editField(.bookingCode) }
            editCard(title: "Seat", value: flight.seat, icon: "chair") { editField(.seat) }
        }
    }

    private func editCard(title: String, value: String?, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(.primary)
                Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(.primary)
                Text(value?.isEmpty == false ? value! : "Tap to Edit")
                    .font(.system(size: 13))
                    .foregroundStyle(value?.isEmpty == false ? ArcTheme.action : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: 14) {
            ShareLink(item: URL(string: "https://arc.flight")!) { actionIcon("square.and.arrow.up") }
            actionIcon("bell")
            actionIcon("ellipsis")
            Spacer()
        }
    }

    private func actionIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 17, weight: .medium))
            .foregroundStyle(.primary).frame(width: 44, height: 44)
            .background(Color(.secondarySystemFill), in: Circle())
    }

    // MARK: Editing

    private var editTitle: String {
        switch editing {
        case .bookingCode: "Booking Code"; case .seat: "Seat"; case .notes: "Notes"; case .none: ""
        }
    }
    private func editField(_ field: EditField) {
        editText = field == .bookingCode ? (flight.bookingCode ?? "") : field == .seat ? (flight.seat ?? "") : flight.notes
        editing = field
    }
    private func saveEdit() {
        switch editing {
        case .bookingCode: flight.bookingCode = editText
        case .seat: flight.seat = editText
        case .notes: flight.notes = editText
        case .none: break
        }
        try? modelContext.save()
        editing = nil
    }
}
