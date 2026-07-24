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
            if !hasSeenIntro {
                FriendsIntroView { hasSeenIntro = true }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    header.padding(.horizontal, 20).padding(.top, 4)

                    if !supabase.isSignedIn {
                        ProfileSetupView()
                    } else {
                        FriendsListView()
                    }
                }
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
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color(.systemGray3), Color(.systemGray5))
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
        .stroke(ArcTheme.routeLine.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [1, 5]))
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

// MARK: - Friends List

/// Owns its own NavigationStack (unlike the setup state) so it can push to
/// FriendDetailView. Data comes from FriendsStore — the same object the
/// shared map reads, so this list and the friend bubbles on the globe are
/// always in sync.
struct FriendsListView: View {
    @ObservedObject private var supabase = ArcSupabase.shared
    @State private var store = FriendsStore.shared
    @State private var showingAddFriend = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let user = supabase.currentUser { profileCard(user) }

                    if let error = store.lastError {
                        Text(error).font(.system(size: 13)).foregroundStyle(.secondary)
                    }

                    if !store.pending.isEmpty {
                        sectionHeader("Friend Requests")
                        ForEach(store.pending, id: \.friendship.id) { item in
                            requestCard(friendship: item.friendship, user: item.user)
                        }
                    }

                    if !store.friends.isEmpty {
                        HStack {
                            sectionHeader("Friends")
                            Button { showingAddFriend = true } label: {
                                Image(systemName: "person.badge.plus")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(ArcTheme.action)
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(store.friends) { entry in
                            NavigationLink { FriendDetailView(entry: entry) } label: {
                                FriendRow(entry: entry)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if store.friends.isEmpty && store.pending.isEmpty && !store.isLoading {
                        VStack(spacing: 12) {
                            Spacer().frame(height: 20)
                            Image(systemName: "person.badge.plus").font(.system(size: 44)).foregroundStyle(.tertiary)
                            Text("No friends yet").font(.system(size: 16, weight: .semibold)).foregroundStyle(.secondary)
                            Button { showingAddFriend = true } label: {
                                Text("Add Friend")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 22).padding(.vertical, 10)
                                    .background(ArcTheme.action, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 140)
            }
            .scrollIndicators(.hidden)
            .refreshable { await store.refresh() }
            .toolbarVisibility(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingAddFriend) {
                AddFriendSheet().presentationDetents([.medium, .large])
            }
            .task { await store.refresh() }
            .alert("You're connected ✈️",
                   isPresented: Binding(get: { store.justRedeemedFriend != nil },
                                        set: { if !$0 { store.justRedeemedFriend = nil } }),
                   presenting: store.justRedeemedFriend) { _ in
                Button("Nice") { store.justRedeemedFriend = nil }
            } message: { friend in
                Text("You and \(friend.display_name) now share flights automatically.")
            }
        }
    }

    // MARK: - Components

    private func profileCard(_ user: ArcSupabase.ArcUser) -> some View {
        HStack(spacing: 14) {
            FriendAvatar(name: user.display_name.isEmpty ? "You" : user.display_name, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(user.display_name.isEmpty ? "You" : user.display_name)
                        .font(.system(size: 15, weight: .semibold))
                    if let nation = user.nationality {
                        Text(String.flag(forRegion: nation)).font(.system(size: 14))
                    }
                }
                Text("That's you").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            if let airport = user.home_airport {
                Text(airport).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(ArcTheme.action)
            }
        }
        .padding(14).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func requestCard(friendship: ArcSupabase.Friendship, user: ArcSupabase.ArcUser) -> some View {
        HStack(spacing: 14) {
            FriendAvatar(name: user.display_name, size: 32)
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

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textCase(.uppercase).tracking(0.8)
    }
}

/// One friend, alive: avatar, name, and what their spotlight flight is doing
/// RIGHT NOW — with a live progress bar while they're in the air.
struct FriendRow: View {
    let entry: FriendsStore.FriendEntry

    var body: some View {
        let flight = entry.spotlight
        HStack(spacing: 14) {
            FriendAvatar(name: entry.user.display_name, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.user.display_name).font(.system(size: 15, weight: .semibold))
                    if let nation = entry.user.nationality {
                        Text(String.flag(forRegion: nation)).font(.system(size: 13))
                    }
                }
                if let f = flight {
                    Text("\(f.departure_iata) → \(f.arrival_iata) · \(f.flight_number)")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    if FriendFlightMath.isAirborne(f) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color(.separator)).frame(height: 3)
                                Capsule().fill(ArcTheme.onTime)
                                    .frame(width: geo.size.width * FriendFlightMath.progress(f), height: 3)
                            }
                        }
                        .frame(height: 3)
                        .padding(.top, 2)
                    }
                } else {
                    Text("No flights right now").font(.system(size: 13)).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let f = flight {
                chipView(FriendFlightMath.chip(for: f))
            } else {
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
        }
        .padding(14).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func chipView(_ chip: (text: String, kind: FriendFlightMath.ChipKind)) -> some View {
        let (bg, fg): (Color, Color) = switch chip.kind {
        case .landed: (ArcTheme.gate, .black)
        case .delayed: (ArcTheme.late, .white)
        case .inFlight: (ArcTheme.onTime, .white)
        case .boarding: (ArcTheme.action, .white)
        case .countdown: (Color(.systemGray5), .primary)
        }
        return HStack(spacing: 3) {
            Image(systemName: chip.kind == .landed ? "airplane.arrival" : "airplane")
                .font(.system(size: 9, weight: .bold))
            Text(chip.text).font(.system(size: 11, weight: .heavy))
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(bg, in: Capsule())
    }
}

// MARK: - Add Friend Sheet

/// Invite-link-first, exactly like Flighty: share a link, the other person
/// opens it and you're connected. Pasting a received link/code lives here
/// too. (No search, no requests, no approvals — links ARE the handshake.)
struct AddFriendSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = FriendsStore.shared
    @State private var inviteURL: URL?
    @State private var pasted = ""
    @State private var redeeming = false
    @State private var redeemError: String?

    private static let inviteBase = "https://arc-backend.owncalai.workers.dev/f/"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Invite with a link", systemImage: "link")
                            .font(.system(size: 15, weight: .bold))
                        Text("Share this link with family or friends. Opening it connects you automatically — no request, no approval. It works for 48 hours.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)

                        if let inviteURL {
                            ShareLink(item: inviteURL,
                                      message: Text("Track my flights with me on Arc ✈️")) {
                                HStack {
                                    Spacer()
                                    Label("Share Invite Link", systemImage: "square.and.arrow.up")
                                        .font(.system(size: 16, weight: .semibold))
                                    Spacer()
                                }
                                .foregroundStyle(.white).padding(14)
                                .background(ArcTheme.action, in: RoundedRectangle(cornerRadius: 12))
                            }
                            Text(inviteURL.absoluteString)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            HStack {
                                Spacer()
                                Label("Creating link…", systemImage: "clock")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(14)
                            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }

                    HStack {
                        Rectangle().fill(Color(.separator)).frame(height: 0.5)
                        Text("or").font(.system(size: 12)).foregroundStyle(.tertiary)
                        Rectangle().fill(Color(.separator)).frame(height: 0.5)
                    }

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
                                .padding(12)
                                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                            Button {
                                Task { await redeem() }
                            } label: {
                                Text(redeeming ? "…" : "Connect")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 16).padding(.vertical, 12)
                                    .background(pasted.isEmpty ? Color(.systemGray4) : ArcTheme.action,
                                                in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .disabled(pasted.isEmpty || redeeming)
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal, 20).padding(.top, 16)
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

// MARK: - Friend Detail

struct FriendDetailView: View {
    let entry: FriendsStore.FriendEntry

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    FriendAvatar(name: entry.user.display_name, size: 64)
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
