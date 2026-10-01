import SwiftUI
import SwiftData

/// Friends before signing in: the first-visit intro, then the one-time
/// profile setup, in the floating surface's standing panel — tall glass,
/// draggable, each scrolling on its own.
struct FriendsSignInPanel: View {
    @AppStorage("hasSeenFriendsIntro") private var hasSeenIntro = false
    /// The name field took the keyboard: the panel opens all the way, so
    /// what the scroll view keeps above the keyboard is inside the glass.
    var onEditing: () -> Void = {}

    /// What the panel keeps showing when dragged down: the top of the intro
    /// or of the setup, enough to read what it is.
    static let headerHeight: CGFloat = 160

    var body: some View {
        // The intro pitches a feature you haven't set up yet; `hasSeenIntro`
        // lives in UserDefaults, which a reinstall wipes even though a
        // session (Keychain) survives — the surface only shows this panel
        // while signed out.
        if !hasSeenIntro {
            FriendsIntroView { hasSeenIntro = true }
        } else {
            ProfileSetupView(onEditing: onEditing)
        }
    }
}

// MARK: - Intro (first visit)

/// Flighty-style feature intro: hero illustration built from our own design
/// language (globe + avatar bubbles with live status pills), what the
/// feature does, fine print, Continue.
struct FriendsIntroView: View {
    var onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                    .frame(height: 250)
                    .padding(.top, 18)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Arc Friends")
                        .font(.system(size: 34, weight: .heavy))
                    Text("Add your family to automatically share upcoming flights, watch each other fly on the map, and get live updates the moment a flight takes off, lands, or changes.")
                        .font(.system(size: 17))
                        .foregroundStyle(.primary.opacity(0.9))
                    Text("No account, no email — just your name. Friends connect through a link.")
                        .font(.system(size: 17))
                        .foregroundStyle(.primary.opacity(0.9))
                    Text("Invite links expire after 48 hours. You can remove friends at any time.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 24)

                Button(action: onContinue) {
                    Text("Continue")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(ArcTheme.action, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.top, 26)
                .padding(.bottom, 32)
            }
        }
        .scrollIndicators(.hidden)
    }

    /// Globe disc + three sample friends with live status pills, connected
    /// by faint arcs — the feature, drawn in the app's own visual language.
    private var hero: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(red: 0.10, green: 0.32, blue: 0.65),
                                              Color(red: 0.03, green: 0.10, blue: 0.28)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 230, height: 230)
                .overlay(Circle().stroke(ArcTheme.routeLine.opacity(0.35), lineWidth: 1))
                .shadow(color: Color(red: 0.1, green: 0.3, blue: 0.7).opacity(0.45), radius: 30, y: 10)

            IntroArc(from: CGPoint(x: -70, y: 40), to: CGPoint(x: 15, y: -55))
            IntroArc(from: CGPoint(x: 15, y: -55), to: CGPoint(x: 95, y: 55))

            heroBubble(name: "Mom", chip: "DELAYED", color: ArcTheme.late)
                .offset(x: -95, y: -20)
            heroBubble(name: "Jenny", chip: "LANDED", color: ArcTheme.gate)
                .offset(x: 92, y: -62)
            heroBubble(name: "Mike", chip: "IN 8H 55M", color: Color(.systemGray))
                .offset(x: 8, y: 62)
        }
    }

    private func heroBubble(name: String, chip: String, color: Color) -> some View {
        VStack(spacing: 5) {
            FriendAvatar(name: name, size: 52)
                .overlay(Circle().stroke(.background, lineWidth: 3))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            HStack(spacing: 3) {
                Image(systemName: "airplane").font(.system(size: 8, weight: .bold))
                Text(chip).font(.system(size: 10, weight: .heavy))
            }
            .foregroundStyle(color == ArcTheme.gate ? .black : .white)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(color, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        }
    }
}

private struct IntroArc: View {
    let from: CGPoint
    let to: CGPoint
    var body: some View {
        Path { p in
            p.move(to: .zero)
            p.addQuadCurve(to: CGPoint(x: to.x - from.x, y: to.y - from.y),
                           control: CGPoint(x: (to.x - from.x) / 2 - 20, y: (to.y - from.y) / 2 - 30))
        }
        .stroke(ArcTheme.routeLine.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [1, 4]))
        .frame(width: 1, height: 1)
        .offset(x: from.x, y: from.y)
    }
}

// MARK: - Profile setup (one-time, replaces sign-in)

/// The whole "account": a name and a passport nationality. Continuing mints
/// an anonymous Supabase user behind the scenes — no email, no code, no
/// approval steps.
struct ProfileSetupView: View {
    var onEditing: () -> Void = {}
    @FocusState private var nameFocused: Bool
    @State private var name = ""
    @State private var region: String = Locale.current.region?.identifier ?? "CH"
    @State private var showRegionPicker = false
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var store = FriendsStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Spacer().frame(height: 6)
                FriendAvatar(name: name.isEmpty ? "?" : name, size: 76)
                    .animation(.easeInOut(duration: 0.2), value: FriendAvatar.initials(of: name))

                VStack(spacing: 6) {
                    Text("Who's flying?").font(.system(size: 26, weight: .heavy))
                    Text("Just a name and your passport — that's the whole setup. Friends see this on the map.")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 30)
                }

                if store.pendingInviteCode != nil {
                    Label("You'll be connected with your friend right after.",
                          systemImage: "person.2.wave.2.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ArcTheme.action)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(ArcTheme.action.opacity(0.12), in: Capsule())
                }

                if let errorMessage {
                    Text(errorMessage).font(.system(size: 13)).foregroundStyle(ArcTheme.late)
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                }

                VStack(spacing: 12) {
                    TextField("Your name", text: $name)
                        .focused($nameFocused)
                        .onChange(of: nameFocused) { _, focused in if focused { onEditing() } }
                        .font(.system(size: 18, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .textInputAutocapitalization(.words)
                        .padding(15)
                        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 14))

                    Button { showRegionPicker = true } label: {
                        HStack {
                            Text("Passport").font(.system(size: 15, weight: .semibold))
                            Spacer()
                            Text("\(String.flag(forRegion: region)) \(regionName(region))")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(ArcTheme.action)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(15)
                        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            Text(isBusy ? "Setting up…" : "Continue")
                                .font(.system(size: 17, weight: .semibold))
                            Spacer()
                        }
                        .foregroundStyle(.white).padding(15)
                        .background(canContinue ? ArcTheme.action : Color(.systemGray4),
                                    in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canContinue)
                }
                .padding(.horizontal, 24)

                Text("No account or email. Your flights stay yours — only friends you link with can see them.")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)

                Spacer().frame(height: 120)
            }
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .sheet(isPresented: $showRegionPicker) {
            NationalityPicker(selection: $region)
        }
    }

    private var canContinue: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !isBusy
    }

    private func regionName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }

    private func submit() async {
        isBusy = true; errorMessage = nil
        do {
            try await ArcSupabase.shared.signInAnonymously(
                displayName: name.trimmingCharacters(in: .whitespaces),
                nationality: region)
            await store.redeemPendingIfPossible()
            await store.refresh(force: true)
        } catch {
            errorMessage = "Couldn't set up your profile: \(error.localizedDescription)"
        }
        isBusy = false
    }
}

/// Searchable country list with flags — the "nation of your passport" pick.
struct NationalityPicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private static let regions: [(code: String, name: String)] = {
        Locale.Region.isoRegions
            .map(\.identifier)
            .filter { $0.count == 2 && $0 != "ZZ" }
            .compactMap { code in
                Locale.current.localizedString(forRegionCode: code).map { (code, $0) }
            }
            .sorted { $0.1 < $1.1 }
    }()

    private var filtered: [(code: String, name: String)] {
        search.isEmpty ? Self.regions
            : Self.regions.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List(filtered, id: \.code) { region in
                Button {
                    selection = region.code
                    dismiss()
                } label: {
                    HStack {
                        Text(String.flag(forRegion: region.code))
                        Text(region.name).foregroundStyle(.primary)
                        Spacer()
                        if region.code == selection {
                            Image(systemName: "checkmark").foregroundStyle(ArcTheme.action)
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Passport")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Friends' Flights feed

/// What the feed (and the globe) is narrowed to. One value rather than two
/// optionals so "a friend" and "a group" can't both be selected at once.
enum FeedFilter: Equatable {
    case all
    case friend(String)
    case group(String)
}

/// Friends' flights as the surface shows them: the filter and what it can be
/// set to, the flights it admits in the stack's order (in the air first,
/// then the next to leave; a flight several friends share is one entry), the
/// past ones, and the two sheets the chips and the menu open.
struct FriendsFeed {
    let filter: Binding<FeedFilter>
    let groups: [FriendGroup]
    let friends: [FriendsStore.FriendEntry]
    let flights: [FriendFlightGroup]
    let past: [FriendFlightGroup]
    let onAdd: () -> Void
    let onManage: () -> Void

    /// The two halves of "can the parked flight be opened yet": WHICH flight a
    /// tap asked for, and WHETHER the feed carries it.
    ///
    /// Keyed on the parked id alone, a cold launch got exactly one attempt.
    /// The tap routes before this view exists, so `.task` fired the instant it
    /// appeared — against a feed that had not been read yet — found nothing,
    /// and never looked again: the app opened on the Friends tab and stopped
    /// there. Warm, the feed was already loaded, which is why it worked every
    /// time it was tried with the app running.
    ///
    /// Presence rather than contents, so that an ordinary feed refresh — which
    /// happens on every visit to this tab — is not mistaken for a new tap.
    static func pendingOpenKey(wanted: String?, feedIds: [String], pastIds: [String]) -> String {
        guard let wanted, !wanted.isEmpty else { return "" }
        let present = feedIds.contains(wanted) || pastIds.contains(wanted)
        return "\(wanted)|\(present)"
    }
}

/// Friends' Flights, minus everything the floating surface draws: the
/// store, the filter and the groups it can pick, the grouped feed, the
/// flight a notification tap parked, the Add Friend and Manage sheets and
/// the "You're connected" alert. The cards, the chips and the chrome are
/// built by `content` from the `FriendsFeed` this hands it.
struct FriendsListView<Content: View>: View {
    @Query private var myFlights: [Flight]
    var onSelect: (FriendFlightGroup) -> Void = { _ in }
    @ViewBuilder var content: (FriendsFeed) -> Content
    @State private var store = FriendsStore.shared
    @State private var showingAddFriend = false
    @State private var showingManage = false
    @State private var filter: FeedFilter = .all
    @State private var groups: [FriendGroup] = []

    /// The people the current filter admits — nil means everyone.
    private var filterIds: Set<String>? {
        switch filter {
        case .all: nil
        case .friend(let id): [id]
        case .group(let id): groups.first { $0.id == id }?.memberIds ?? []
        }
    }

    private var feed: FriendsFeed {
        FriendsFeed(filter: $filter,
                    groups: groups,
                    friends: store.friends,
                    flights: journeyGroups(past: false),
                    past: journeyGroups(past: true),
                    onAdd: { showingAddFriend = true },
                    onManage: { showingManage = true })
    }

    var body: some View {
        content(feed)
            // A notification tap parks the flight it named; open it once
            // the feed carries it. Runs on appear as well as on change,
            // because a cold launch routes BEFORE this view exists — and
            // keyed on whether the feed HAS it, because on a cold launch
            // the feed has not loaded yet when this view first appears.
            .task(id: pendingOpenKey) { openPendingFlightIfPossible() }
            .toolbarVisibility(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingAddFriend) {
                AddFriendSheet().presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingManage, onDismiss: {
                groups = FriendGroups.all()
                // The filter may point at a friend or group that no longer
                // exists — an empty-set filter showed nothing with no chip lit.
                switch filter {
                case .friend(let id) where !store.friends.contains(where: { $0.id == id }): filter = .all
                case .group(let id) where !groups.contains(where: { $0.id == id }): filter = .all
                default: break
                }
                store.mapFilterIds = filterIds
            }) {
                ManageFriendsSheet()
            }
            // The globe mirrors the list's filter, friend or group.
            .onChange(of: filter) { _, _ in store.mapFilterIds = filterIds }
            // Leaving clears the globe's filter; coming back puts the chip's
            // back, so the two never disagree.
            .onAppear { store.mapFilterIds = filterIds }
            .onDisappear { store.mapFilterIds = nil }
            .task {
                groups = FriendGroups.all()
                await store.refresh()
            }
            .alert("You're connected ✈️",
                   isPresented: Binding(get: { store.justRedeemedFriend != nil },
                                        set: { if !$0 { store.justRedeemedFriend = nil } }),
                   presenting: store.justRedeemedFriend) { _ in
                Button("Nice") { store.justRedeemedFriend = nil }
            } message: { friend in
                Text("You and \(friend.display_name) now share flights automatically.")
            }
    }

    // MARK: Feed

    private func journeyGroups(past: Bool) -> [FriendFlightGroup] {
        let current = store.feed
        let activeIDs = Set(current.map(\.id))
        return FriendFlightGroup.group(current + store.pastFeed, myFlights: myFlights).filter { group in
            let isPast = !activeIDs.contains(group.representative.id)
            let matchesFilter = filterIds.map { ids in group.users.contains { ids.contains($0.id) } } ?? true
            return isPast == past && matchesFilter
        }
    }

    private var pendingOpenKey: String {
        FriendsFeed.pendingOpenKey(wanted: store.pendingFlightId,
                                   feedIds: store.feed.map(\.flight.id),
                                   pastIds: store.pastFeed.map(\.flight.id))
    }

    /// Drain `pendingFlightId` — the friend flight a tapped alert asked for.
    /// Silently gives up if the row is not in the feed (a landing past its
    /// grace drops out of it); opening the wrong flight would be worse than
    /// opening none, which is exactly what the missing routing used to do.
    private func openPendingFlightIfPossible() {
        guard let wanted = store.pendingFlightId else { return }
        let everything = store.feed + store.pastFeed
        guard let item = everything.first(where: { $0.flight.id == wanted }) else {
            // Once the feed has genuinely loaded and the row isn't in it,
            // release the park — left set, the stale id sat there forever
            // and could hijack a much later refresh into presenting a sheet
            // nobody asked for anymore.
            if store.hasLoadedOnce, !store.isLoading { store.pendingFlightId = nil }
            return
        }
        store.pendingFlightId = nil
        if let group = FriendFlightGroup.group(everything, myFlights: myFlights).first(where: { $0.items.contains { $0.id == item.id } }) { onSelect(group) }
    }
}

/// One friend-flight in the feed, styled like a My Flights row: the same
/// countdown column on the left, the travellers beside the number.
struct FriendFlightRow: View {
    let group: FriendFlightGroup
    private var item: FriendsStore.FeedItem { group.representative }

    private var flight: ArcSupabase.SharedFlight { item.flight }
    private var airborne: Bool { FriendFlightMath.isAirborne(flight) }
    /// Green is a report of punctuality; a timetable-only leg (or a landed
    /// one) has none to colour by.
    private var tint: Color {
        guard flight.tier.reportsPunctuality, flight.status != "landed" else { return Color(.secondaryLabel) }
        return flight.delay_minutes > 0 ? ArcTheme.late : ArcTheme.onTime
    }

    var body: some View {
        // A minute heartbeat so the countdown/context lines stay honest while
        // the tab sits open — same rhythm as the map bubbles.
        TimelineView(.periodic(from: .now, by: 60)) { context in
        HStack(alignment: .center, spacing: 14) {
            // The travellers are named in the avatar stack beside the number,
            // so this column is the same countdown as your own trips.
            TripCountdownBlock(state: TripCountdown(flight, at: context.date), mode: flight.tripMode)
                .frame(width: 56)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    TripLogoView(mode: flight.tripMode,
                                 iata: flight.tripMode == .air ? String(flight.flight_number.prefix(2)) : "",
                                 logoURL: flight.operator_logo_url, size: 18)
                    Text(flight.flight_number)
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                        .lineLimit(1)
                    TravellerAvatarStack(users: group.users, includesMe: group.myFlightID != nil)
                    Spacer(minLength: 8)
                    Text(contextLine(at: context.date))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(contextColor)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                        .animation(.default, value: contextLine(at: context.date))
                }
                TextHelpers.cityPair(flight.departure_city, flight.arrival_city, size: 18, weight: .medium)
                    .lineLimit(1)
                HStack(spacing: 16) {
                    endpointChip(arrow: "arrow.up.right", iata: flight.departure_iata,
                                 time: FriendFlightMath.localHHmm(FriendFlightMath.departure(flight), at: flight.departure_iata))
                    endpointChip(arrow: "arrow.down.right", iata: flight.arrival_iata,
                                 time: FriendFlightMath.localHHmm(FriendFlightMath.arrival(flight), at: flight.arrival_iata))
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .contentShape(Rectangle())
        }
    }

    /// Only facts we actually have. The old line invented a "True Curb ETA
    /// +35m" constant for every landed flight — fabricated intelligence.
    private func contextLine(at now: Date) -> String {
        let mode = flight.tripMode
        switch FriendFlightMath.departurePhase(flight, at: now) {
        case .taxiing:
            guard let taxi = FriendFlightMath.taxiElapsed(flight, at: now), taxi >= 60 else {
                return "Taxiing"
            }
            return "Taxiing for \(FriendFlightMath.hmLower(Int(taxi / 60)))"
        case .departing:
            return "Takeoff not yet confirmed"
        case .beforeDeparture, .presumedAirborne, .airborne: break
        }
        if airborne, let arr = FriendFlightMath.arrival(flight) {
            return "\(mode.arrivingVerb) in \(FriendFlightMath.hmLower(Int(arr.timeIntervalSince(now) / 60)))"
        }
        if flight.status == "cancelled" { return "Cancelled" }
        if flight.status == "landed" {
            if let arr = FriendFlightMath.arrival(flight), arr <= now {
                return "\(mode.arrivedVerb) \(FriendFlightMath.hmLower(Int(now.timeIntervalSince(arr) / 60))) ago"
            }
            return mode.arrivedVerb
        }
        // Clock past the schedule, source silent: say exactly that. But only
        // once the flight has actually LEFT — the arrival branches are gated
        // on the departure, because a flight that hasn't departed has no
        // arrival story whatever a (possibly contaminated) estimate says: the
        // old order put "Arrival not yet confirmed" on a flight still an
        // hour from pushback.
        if FriendFlightMath.departure(flight).map({ $0 <= now }) ?? false {
            if FriendFlightMath.arrival(flight).map({ $0 <= now }) ?? false {
                return "Arrival not yet confirmed"
            }
            return "Departed"
        }
        // Punctuality only where somebody actually reported it. A friend's ferry
        // has a timetable and no revised time, so "On Time" would be this app
        // inventing a fact about someone else's journey — and an operator notice
        // is the one thing a sailing genuinely does tell us.
        guard flight.tier.reportsPunctuality else {
            if flight.disruption_note != nil { return "Operator notice" }
            return flight.tier.qualifier ?? "Scheduled"
        }
        if flight.delay_minutes > 0 { return "Departs \(FlightClock.delayText(flight.delay_minutes)) late" }
        return "On Time"
    }

    private var contextColor: Color {
        if !flight.tier.reportsPunctuality {
            return flight.disruption_note != nil ? .orange : Color(.secondaryLabel)
        }
        if flight.delay_minutes > 0 && !airborne && flight.status != "landed" { return ArcTheme.late }
        if airborne || flight.status != "landed" { return ArcTheme.onTime }
        return Color(.secondaryLabel)
    }

    private func endpointChip(arrow: String, iata: String, time: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: arrow)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(tint, in: Circle())
            Text(iata).font(.system(size: 13)).foregroundStyle(.primary)
            Text(time)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint)
        }
    }
}

// MARK: - Add Friend Sheet

/// Invite-link-first, exactly like Flighty: share a link, the other person
/// opens it and you're connected. Pasting a received link/code lives here
/// too. (No search, no requests, no approvals — links ARE the handshake.)
struct AddFriendSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var supabase = ArcSupabase.shared
    @State private var store = FriendsStore.shared
    @State private var inviteURL: URL?
    @State private var inviteError: String?
    @State private var pasted = ""
    @State private var redeeming = false
    @State private var redeemError: String?

    private static let inviteBase = ArcConfig.defaultAPIEndpoint + "/f/"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    hero
                        .padding(.top, 28)

                    VStack(spacing: 8) {
                        Text("Invite with a link")
                            .font(.system(size: 24, weight: .heavy))
                        Text("Opening your link connects you automatically — no requests, no approvals. Links work for 48 hours.")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }
                    .padding(.top, 22)

                    VStack(spacing: 10) {
                        if let inviteURL {
                            ShareLink(item: inviteURL,
                                      message: Text("Track my flights with me on Arc ✈️")) {
                                pillLabel("Share invite", loading: false)
                            }
                            Text(inviteURL.absoluteString.replacingOccurrences(of: "https://", with: ""))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        } else if inviteError != nil {
                            // A failed mint used to leave "Creating link…"
                            // spinning forever with nothing to tap.
                            Button { Task { await createInvite() } } label: {
                                pillLabel("Try again", loading: false)
                            }
                            .buttonStyle(.plain)
                            Text("Couldn't create an invite link — check your connection.")
                                .font(.system(size: 12)).foregroundStyle(ArcTheme.late)
                        } else {
                            pillLabel("Creating link…", loading: true)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)

                    HStack(spacing: 10) {
                        line
                        Text("or").font(.system(size: 12)).foregroundStyle(.tertiary)
                        line
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 22)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Got an invite?", systemImage: "envelope.open")
                            .font(.system(size: 15, weight: .bold))
                        if let redeemError {
                            Text(redeemError).font(.system(size: 13)).foregroundStyle(ArcTheme.late)
                        }
                        HStack(spacing: 10) {
                            TextField("Paste link or code", text: $pasted)
                                .font(.system(size: 15))
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .padding(.horizontal, 16).padding(.vertical, 12)
                                .background(Color(.secondarySystemFill), in: Capsule())
                            Button {
                                Task { await redeem() }
                            } label: {
                                Text(redeeming ? "…" : "Connect")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 18).padding(.vertical, 12)
                                    .background(pasted.isEmpty ? Color(.systemGray4) : ArcTheme.action,
                                                in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(pasted.isEmpty || redeeming)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 30)
                }
            }
            .navigationTitle("Add Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.foregroundStyle(ArcTheme.action)
                }
            }
            .task { await createInvite() }
        }
    }

    /// You ···✈··· them: your avatar linked to the friend-to-be.
    private var hero: some View {
        let myName = supabase.currentUser?.display_name ?? "You"
        return HStack(spacing: 0) {
            VStack(spacing: 6) {
                FriendAvatar(name: myName.isEmpty ? "You" : myName, size: 62,
                             avatarURL: supabase.currentUser?.avatar_url)
                    .overlay(Circle().stroke(.background, lineWidth: 3))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                Text("You").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }

            VStack(spacing: 3) {
                Image(systemName: "airplane")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(ArcTheme.action)
                Rectangle()
                    .fill(.clear)
                    .frame(width: 74, height: 1)
                    .overlay(
                        Line()
                            .stroke(ArcTheme.routeLine.opacity(0.7),
                                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [1, 4]))
                    )
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 16)

            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(Color(.secondarySystemFill))
                        .frame(width: 62, height: 62)
                    Circle()
                        .stroke(ArcTheme.action.opacity(0.6),
                                style: StrokeStyle(lineWidth: 2, dash: [4, 5]))
                        .frame(width: 62, height: 62)
                    Image(systemName: "person.fill.questionmark")
                        .font(.system(size: 24))
                        .foregroundStyle(ArcTheme.action)
                }
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                Text("Your friend").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
    }

    private var line: some View {
        Rectangle().fill(Color(.separator)).frame(height: 0.5)
    }

    private func pillLabel(_ text: String, loading: Bool) -> some View {
        HStack(spacing: 8) {
            Spacer()
            if loading { ProgressView().tint(.white) }
            Text(text).font(.system(size: 17, weight: .semibold))
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.vertical, 16)
        .background(loading ? Color(.systemGray4) : ArcTheme.action, in: Capsule())
    }

    /// Mints the shareable link, retryably. The one-shot `.task` version left
    /// "Creating link…" spinning forever on any failure, with nothing to tap.
    private func createInvite() async {
        guard inviteURL == nil else { return }
        inviteError = nil
        do {
            // A session that never finished loading its profile throws
            // notSignedIn here despite the user being signed in — retry it
            // first rather than failing a signed-in user.
            await ArcSupabase.shared.ensureProfileLoaded()
            let code = try await ArcSupabase.shared.createFriendInvite()
            inviteURL = URL(string: Self.inviteBase + code)
        } catch {
            inviteError = error.localizedDescription
        }
    }

    /// Accepts a full link ("…/f/abc123"), an arc:// link, or a bare code.
    private func redeem() async {
        redeeming = true; redeemError = nil
        var code = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = code.range(of: "/f/") { code = String(code[range.upperBound...]) }
        if let range = code.range(of: "friend/") { code = String(code[range.upperBound...]) }
        code = code.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()

        // nil MEANS invalid now; a failure to reach the server throws instead.
        // Conflated, a flaky connection told the user their friend's link was
        // dead — an invitation to ask for a new link that would fail the same
        // way.
        do {
            await ArcSupabase.shared.ensureProfileLoaded()
            if let friend = try await ArcSupabase.shared.redeemInvite(code: code.lowercased()) {
                store.justRedeemedFriend = friend
                await store.refresh(force: true)
                dismiss()
            } else {
                redeemError = "That invite isn't valid anymore — ask for a fresh link."
            }
        } catch {
            redeemError = "Couldn't reach the server — check your connection and try again."
        }
        redeeming = false
    }
}

/// Straight dashed connector for the invite hero.
private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}
