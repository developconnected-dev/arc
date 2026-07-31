import SwiftUI

/// The Friends sheet content: intro takeover on first visit, then title +
/// share/avatar row and either the one-time profile setup or the live
/// friends list, matching the other tabs' bottom-sheet layout (no standalone
/// NavigationStack at the top level — that's reserved for the signed-in
/// content, which needs to push to FriendDetailView).
struct FriendsScreen: View {
    @ObservedObject private var supabase = ArcSupabase.shared
    @AppStorage("hasSeenFriendsIntro") private var hasSeenIntro = false
    @State private var showSettings = false

    var body: some View {
        Group {
            // The intro pitches a feature you haven't set up yet, so an already
            // signed-in user skips it — `hasSeenIntro` lives in UserDefaults,
            // which a reinstall wipes even though the session (Keychain) survives.
            if !hasSeenIntro && !supabase.isSignedIn {
                FriendsIntroView { hasSeenIntro = true }
            } else if !supabase.isSignedIn {
                VStack(alignment: .leading, spacing: 0) {
                    header.padding(.horizontal, 20).padding(.top, 4)
                    ProfileSetupView()
                }
            } else {
                // Signed in → the Friends' Flights feed, which owns its own
                // header (title ⇄ expanding search, add-friends, settings).
                FriendsListView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Friends").font(ArcTheme.screenTitle)
            Spacer()
            Button { showSettings = true } label: {
                ProfileButtonIcon(size: 34)
            }.buttonStyle(.plain)
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
                .padding(.bottom, 120)
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
            await store.refresh()
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

/// Flighty's Friends' Flights page: one flight-centric feed across all
/// friends. Header swaps between the title and an expanding search field;
/// the always-visible Add chip and the avatar filter row sit above the
/// feed. Owns its own NavigationStack so rows can push FriendDetailView.
/// What the feed (and the globe) is narrowed to. One value rather than two
/// optionals so "a friend" and "a group" can't both be selected at once.
enum FeedFilter: Equatable {
    case all
    case friend(String)
    case group(String)
}

struct FriendsListView: View {
    @ObservedObject private var supabase = ArcSupabase.shared
    @State private var store = FriendsStore.shared
    @State private var showingAddFriend = false
    @State private var showingManage = false
    @State private var showSettings = false
    @State private var filter: FeedFilter = .all
    @State private var groups: [FriendGroup] = []
    @State private var presentedFlight: Flight?

    /// The people the current filter admits — nil means everyone.
    private var filterIds: Set<String>? {
        switch filter {
        case .all: nil
        case .friend(let id): [id]
        case .group(let id): groups.first { $0.id == id }?.memberIds ?? []
        }
    }

    var body: some View {
        // No NavigationStack here: it paints an opaque system background
        // over the bottom-sheet material. Friend detail presents as a sheet.
        VStack(spacing: 0) {
                headerRow
                    .padding(.horizontal, 20).padding(.top, 8)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        filterRow
                        content
                    }
                    .padding(.top, 12).padding(.bottom, 140)
                }
                .scrollIndicators(.hidden)
                .refreshable { await store.refresh() }
            }
            .toolbarVisibility(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingAddFriend) {
                AddFriendSheet().presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingManage, onDismiss: { groups = FriendGroups.all() }) {
                ManageFriendsSheet()
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(item: $presentedFlight, onDismiss: { store.focusedRoute = nil }) { flight in
                FlightDetailView(flight: flight, isOwnFlight: false)
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
            // The globe mirrors the list's filter, friend or group.
            .onChange(of: filter) { _, _ in store.mapFilterIds = filterIds }
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

    // MARK: Header
    //
    // Search used to live here and has been dropped: with a family-sized
    // friends list the feed is short and the chips below already narrow it,
    // so a search field was a second way to do the same thing. Manage takes
    // the slot — it's the action you actually reach for.

    private var headerRow: some View {
        HStack(spacing: 10) {
            Text("Friends' Flights")
                .font(ArcTheme.screenTitle)
                .lineLimit(1).minimumScaleFactor(0.7)
            Spacer()
            if !store.friends.isEmpty {
                Button { showingManage = true } label: {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary).frame(width: 36, height: 36)
                        .background(Color(.secondarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Manage friends and groups")
            }
            Button { showSettings = true } label: {
                ProfileButtonIcon(size: 34)
            }.buttonStyle(.plain)
        }
    }

    // MARK: Filter chips (Add · All · one per friend)

    private var filterRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Button { showingAddFriend = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.badge.plus").font(.system(size: 13, weight: .bold))
                        Text("Add Friends").font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(ArcTheme.action, in: Capsule())
                }.buttonStyle(.plain)

                if !store.friends.isEmpty {
                    filterChip("All", filter: .all)
                    ForEach(groups) { group in groupChip(group) }
                    ForEach(store.friends) { entry in friendChip(entry) }
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
    }

    private func filterChip(_ label: String, filter target: FeedFilter) -> some View {
        let selected = filter == target
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { filter = target }
        } label: {
            Text(label).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(selected ? Color(.systemBackground) : .primary)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(selected ? Color.primary : Color(.secondarySystemFill), in: Capsule())
        }.buttonStyle(.plain)
    }

    /// A group reads as one chip with a small stack of its members' faces, so
    /// "Family" is recognisable at a glance next to the individual chips.
    private func groupChip(_ group: FriendGroup) -> some View {
        let selected = filter == .group(group.id)
        let faces = store.friends.filter { group.memberIds.contains($0.id) }.prefix(3)
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                filter = selected ? .all : .group(group.id)
            }
        } label: {
            HStack(spacing: 6) {
                HStack(spacing: -8) {
                    ForEach(Array(faces)) { entry in
                        FriendAvatar(name: entry.user.display_name, size: 24,
                                     avatarURL: entry.user.avatar_url)
                            .overlay(Circle().stroke(selected ? Color.primary : Color(.secondarySystemFill),
                                                     lineWidth: 1.5))
                    }
                }
                Text(group.name).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selected ? Color(.systemBackground) : .primary)
            }
            .padding(.leading, faces.isEmpty ? 13 : 5).padding(.trailing, 13).padding(.vertical, 5)
            .background(selected ? Color.primary : Color(.secondarySystemFill), in: Capsule())
        }.buttonStyle(.plain)
    }

    private func friendChip(_ entry: FriendsStore.FriendEntry) -> some View {
        let selected = filter == .friend(entry.id)
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                filter = selected ? .all : .friend(entry.id)
            }
        } label: {
            HStack(spacing: 6) {
                FriendAvatar(name: entry.user.display_name, size: 26, avatarURL: entry.user.avatar_url)
                Text(entry.user.display_name).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selected ? Color(.systemBackground) : .primary)
            }
            .padding(.leading, 4).padding(.trailing, 13).padding(.vertical, 4)
            .background(selected ? Color.primary : Color(.secondarySystemFill), in: Capsule())
        }.buttonStyle(.plain)
        // Long-press: how much this friend's flying may interrupt you.
        .contextMenu {
            let current = FriendAlerts.level(for: entry.id)
            ForEach(FriendNotificationLevel.allCases) { level in
                Button {
                    FriendAlerts.setLevel(level, for: entry.id)
                    Task { await FriendAlerts.process(entries: store.friends) }
                } label: {
                    Label(level.title, systemImage: current == level ? "checkmark" : level.icon)
                }
            }
        }
    }

    // MARK: Feed

    private var filteredFeed: [FriendsStore.FeedItem] {
        guard let ids = filterIds else { return store.feed }
        return store.feed.filter { ids.contains($0.user.id) }
    }

    @ViewBuilder private var content: some View {
        if let error = store.lastError {
            Text(error).font(.system(size: 13)).foregroundStyle(.secondary)
                .padding(.horizontal, 20)
        }

        if !store.pending.isEmpty {
            VStack(spacing: 10) {
                ForEach(store.pending, id: \.friendship.id) { item in
                    requestCard(friendship: item.friendship, user: item.user)
                }
            }
            .padding(.horizontal, 20)
        }

        let items = filteredFeed
        if !items.isEmpty {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    Button {
                        presentedFlight = store.transientFlight(for: item)
                        // Zoom the globe onto this flight's arc behind the
                        // half-height detail.
                        if let dlat = item.flight.departure_lat, let dlon = item.flight.departure_lon,
                           let alat = item.flight.arrival_lat, let alon = item.flight.arrival_lon {
                            store.focusedRoute = .init(
                                id: item.flight.id,
                                dep: .init(latitude: dlat, longitude: dlon),
                                arr: .init(latitude: alat, longitude: alon))
                        }
                    } label: {
                        FriendFlightRow(item: item)
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 84)
                }
            }
        } else if store.friends.isEmpty && store.pending.isEmpty && !store.isLoading {
            VStack(spacing: 12) {
                Spacer().frame(height: 30)
                Image(systemName: "person.2.wave.2").font(.system(size: 44)).foregroundStyle(.tertiary)
                Text("No friends yet").font(.system(size: 16, weight: .semibold)).foregroundStyle(.secondary)
                Text("Share an invite link — connecting takes one tap.")
                    .font(.system(size: 13)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
        } else if !store.isLoading {
            VStack(spacing: 10) {
                Spacer().frame(height: 30)
                Image(systemName: "airplane.circle").font(.system(size: 40)).foregroundStyle(.tertiary)
                Text(filter == .all ? "No flights right now" : "No flights in this filter")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func requestCard(friendship: ArcSupabase.Friendship, user: ArcSupabase.ArcUser) -> some View {
        HStack(spacing: 14) {
            FriendAvatar(name: user.display_name, size: 32, avatarURL: user.avatar_url)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.display_name).font(.system(size: 15, weight: .semibold))
                Text("Wants to be friends").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Accept") {
                Task {
                    try? await supabase.acceptFriendRequest(friendshipId: friendship.id)
                    await store.refresh()
                }
            }
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(ArcTheme.action, in: Capsule())
        }
        .padding(14).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// One friend-flight in the feed, styled like a My Flights row with the
/// friend's identity on the left: avatar + a tiny live-status caption.
struct FriendFlightRow: View {
    let item: FriendsStore.FeedItem

    private var flight: ArcSupabase.SharedFlight { item.flight }
    private var airborne: Bool { FriendFlightMath.isAirborne(flight) }
    private var tint: Color { flight.delay_minutes > 0 ? ArcTheme.late : ArcTheme.onTime }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(spacing: 4) {
                FriendAvatar(name: item.user.display_name, size: 46, avatarURL: item.user.avatar_url)
                Text(statusMini)
                    .font(.system(size: 9, weight: .heavy)).tracking(0.5)
                    .foregroundStyle(airborne ? ArcTheme.action : .secondary)
                    .lineLimit(1)
            }
            .frame(width: 56)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    AirlineLogoView(iata: String(flight.flight_number.prefix(2)), size: 18)
                    Text(flight.flight_number)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(contextLine)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(contextColor)
                        .lineLimit(1)
                }
                TextHelpers.cityPair(flight.departure_city, flight.arrival_city, size: 17)
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

    private var statusMini: String {
        if airborne { return "IN AIR" }
        if flight.status == "landed" { return "LANDED" }
        if let dep = FriendFlightMath.departure(flight), dep > .now {
            let mins = Int(dep.timeIntervalSinceNow / 60)
            return mins >= 60 ? "IN \(mins / 60)H" : "IN \(mins)M"
        }
        return "LANDED"
    }

    private var contextLine: String {
        if airborne, let arr = FriendFlightMath.arrival(flight) {
            return "Landing in \(FriendFlightMath.hmLower(Int(arr.timeIntervalSinceNow / 60)))"
        }
        if flight.status == "landed" { return "Landed • True Curb ETA +35m" }
        if flight.delay_minutes > 0 { return "Departs \(flight.delay_minutes)m late" }
        if let dep = FriendFlightMath.departure(flight), dep <= .now { return "Landed • True Curb ETA +35m" }
        return "On Time"
    }

    private var contextColor: Color {
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
            Text(iata).font(.system(size: 14, weight: .bold)).foregroundStyle(.primary)
            Text(time)
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
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
    @State private var pasted = ""
    @State private var redeeming = false
    @State private var redeemError: String?

    private static let inviteBase = "https://arc-backend.owncalai.workers.dev/f/"

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
                                pillLabel("Continue", loading: false)
                            }
                            Text(inviteURL.absoluteString.replacingOccurrences(of: "https://", with: ""))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.tertiary)
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
            .task {
                if inviteURL == nil, let code = try? await ArcSupabase.shared.createFriendInvite() {
                    inviteURL = URL(string: Self.inviteBase + code)
                }
            }
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

    /// Accepts a full link ("…/f/abc123"), an arc:// link, or a bare code.
    private func redeem() async {
        redeeming = true; redeemError = nil
        var code = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = code.range(of: "/f/") { code = String(code[range.upperBound...]) }
        if let range = code.range(of: "friend/") { code = String(code[range.upperBound...]) }
        code = code.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()

        if let friend = try? await ArcSupabase.shared.redeemInvite(code: code.lowercased()) {
            store.justRedeemedFriend = friend
            await store.refresh()
            dismiss()
        } else {
            redeemError = "That invite isn't valid anymore — ask for a fresh link."
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

// MARK: - Friend Detail

struct FriendDetailView: View {
    let entry: FriendsStore.FriendEntry

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    FriendAvatar(name: entry.user.display_name, size: 64, avatarURL: entry.user.avatar_url)
                    HStack(spacing: 8) {
                        Text(entry.user.display_name).font(.system(size: 22, weight: .bold))
                        if let nation = entry.user.nationality {
                            Text(String.flag(forRegion: nation)).font(.system(size: 20))
                        }
                    }
                }
                .padding(.top, 24)

                if entry.flights.isEmpty {
                    Text("No shared flights").font(.system(size: 15)).foregroundStyle(.tertiary).padding(.top, 24)
                } else {
                    ForEach(entry.flights) { flight in friendFlightCard(flight) }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 24)
        }
        .navigationTitle(entry.user.display_name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func friendFlightCard(_ flight: ArcSupabase.SharedFlight) -> some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(flight.departure_iata).font(.system(size: 16, weight: .semibold, design: .monospaced))
                    Text(flight.departure_city).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(spacing: 1) {
                    Text(flight.flight_number).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    if let dep = DateHelpers.parseAPIDate(flight.scheduled_departure) {
                        Text(dep.formatted(.dateTime.day().month())).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(flight.arrival_iata).font(.system(size: 16, weight: .semibold, design: .monospaced))
                    Text(flight.arrival_city).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.separator)).frame(height: 3)
                    Capsule().fill(ArcTheme.action)
                        .frame(width: geo.size.width * FriendFlightMath.progress(flight), height: 3)
                }
            }.frame(height: 3)
            HStack {
                Text(FriendFlightMath.chip(for: flight).text)
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(flight.delay_minutes > 0 ? ArcTheme.late : ArcTheme.onTime)
                Spacer()
                if flight.delay_minutes > 0 {
                    Text("+\(flight.delay_minutes)m").font(.system(size: 13, weight: .semibold)).foregroundStyle(ArcTheme.late)
                }
            }
        }
        .padding(14).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
