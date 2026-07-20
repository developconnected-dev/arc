import SwiftUI

/// The Friends sheet content: title + share/avatar row, then either sign-in
/// or the friends list, matching the other tabs' bottom-sheet layout (no
/// standalone NavigationStack at the top level — that's reserved for the
/// signed-in content, which needs to push to FriendDetailView).
struct FriendsScreen: View {
    @ObservedObject private var supabase = ArcSupabase.shared
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 20).padding(.top, 4)

            if !supabase.isConfigured {
                setupPrompt
            } else if !supabase.isSignedIn {
                SignInContent()
            } else {
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
            ShareLink(item: URL(string: "https://arc.flight")!) { circleIcon("square.and.arrow.up") }
            Button { showSettings = true } label: {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color(.systemGray3), Color(.systemGray5))
            }.buttonStyle(.plain)
        }
    }

    private func circleIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary).frame(width: 36, height: 36)
            .background(Color(.secondarySystemFill), in: Circle())
    }

    private var setupPrompt: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "person.2.fill").font(.system(size: 52)).foregroundStyle(.tertiary)
            Text("Set Up Social").font(.system(size: 20, weight: .bold))
            Text("Connect Supabase in Settings to use Friends and Shared Journeys.")
                .font(.system(size: 14)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Sign In

/// Email code is the primary path — it works with zero extra setup. Sign in
/// with Apple is offered too, but only actually works once Apple's side
/// (Services ID + key) is configured in the Supabase dashboard, so its
/// caption says so rather than pretending it's ready.
struct SignInContent: View {
    @ObservedObject private var supabase = ArcSupabase.shared
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Spacer().frame(height: 8)
                Image(systemName: "person.crop.circle").font(.system(size: 52)).foregroundStyle(ArcTheme.action)
                VStack(spacing: 6) {
                    Text("Sign In").font(.system(size: 22, weight: .bold))
                    Text("Sign in to share flights, track friends, and create live journey links.")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                }

                if let errorMessage {
                    Text(errorMessage).font(.system(size: 13)).foregroundStyle(ArcTheme.late)
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                }

                VStack(spacing: 10) {
                    if !codeSent {
                        TextField("you@example.com", text: $email)
                            .font(.system(size: 16))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                            .padding(14).background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                        actionButton(title: isBusy ? "Sending…" : "Send Code", disabled: !isValidEmail || isBusy) {
                            await sendCode()
                        }
                    } else {
                        Text("Code sent to \(email)").font(.system(size: 13)).foregroundStyle(.secondary)
                        TextField("6-digit code", text: $code)
                            .font(.system(size: 20, weight: .semibold, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .keyboardType(.numberPad)
                            .padding(14).background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                        actionButton(title: isBusy ? "Verifying…" : "Verify & Sign In", disabled: code.count < 6 || isBusy) {
                            await verifyCode()
                        }
                        Button("Use a different email") {
                            codeSent = false; code = ""; errorMessage = nil
                        }
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(ArcTheme.action)
                    }
                }
                .padding(.horizontal, 24)

                HStack { line; Text("or").font(.system(size: 12)).foregroundStyle(.tertiary); line }
                    .padding(.horizontal, 24)

                VStack(spacing: 6) {
                    AppleSignInButton(errorMessage: $errorMessage)
                        .frame(height: 50).frame(maxWidth: 280).cornerRadius(12)
                    Text("Requires Sign in with Apple to be configured in Supabase Auth settings.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center).padding(.horizontal, 40)
                }

                Spacer().frame(height: 20)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 140)
        }
        .scrollIndicators(.hidden)
    }

    private var line: some View { Rectangle().fill(Color(.separator)).frame(height: 0.5) }

    private var isValidEmail: Bool { email.contains("@") && email.contains(".") && !email.isEmpty }

    private func actionButton(title: String, disabled: Bool, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            HStack { Spacer(); Text(title).font(.system(size: 16, weight: .semibold)); Spacer() }
                .foregroundStyle(.white).padding(14)
                .background(disabled ? Color(.systemGray4) : ArcTheme.action, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func sendCode() async {
        isBusy = true; errorMessage = nil
        do {
            try await supabase.requestEmailCode(email: email.trimmingCharacters(in: .whitespaces))
            codeSent = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }

    private func verifyCode() async {
        isBusy = true; errorMessage = nil
        do {
            try await supabase.verifyEmailCode(email: email.trimmingCharacters(in: .whitespaces), code: code)
        } catch {
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }
}

// MARK: - Sign In With Apple

import AuthenticationServices
import CryptoKit

struct AppleSignInButton: View {
    @ObservedObject private var supabase = ArcSupabase.shared
    @Binding var errorMessage: String?

    var body: some View {
        SignInWithAppleButton(.signIn, onRequest: { request in
            let nonce = randomNonceString()
            currentNonce = nonce
            request.requestedScopes = [.fullName, .email]
            request.nonce = sha256(nonce)
        }, onCompletion: { result in
            switch result {
            case .success(let authorization):
                if let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
                   let identityToken = appleIDCredential.identityToken,
                   let tokenString = String(data: identityToken, encoding: .utf8),
                   let nonce = currentNonce {
                    Task {
                        do {
                            try await supabase.signInWithApple(idToken: tokenString, nonce: nonce)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        })
        .signInWithAppleButtonStyle(.white)
    }

    @State private var currentNonce: String?

    private func randomNonceString(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length
        while remainingLength > 0 {
            let randoms: [UInt8] = (0..<16).map { _ in
                var random: UInt8 = 0
                let errorCode = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
                if errorCode != errSecSuccess { fatalError("SecRandomCopyBytes failed") }
                return random
            }
            randoms.forEach { random in
                if remainingLength == 0 { return }
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }
        return result
    }

    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Friends List

/// Owns its own NavigationStack (unlike the sign-in/setup states) so it can
/// push to FriendDetailView the same way it did before this screen was
/// reconnected into the bottom-sheet layout.
struct FriendsListView: View {
    @ObservedObject private var supabase = ArcSupabase.shared
    @State private var friends: [(ArcSupabase.Friendship, ArcSupabase.ArcUser)] = []
    @State private var pendingRequests: [(ArcSupabase.Friendship, ArcSupabase.ArcUser)] = []
    @State private var showingAddFriend = false
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let user = supabase.currentUser { profileCard(user) }

                    if let errorMessage {
                        Text(errorMessage).font(.system(size: 13)).foregroundStyle(.secondary)
                    }

                    if !pendingRequests.isEmpty {
                        sectionHeader("Friend Requests")
                        ForEach(pendingRequests, id: \.0.id) { friendship, user in
                            requestCard(friendship: friendship, user: user)
                        }
                    }

                    if !friends.isEmpty {
                        sectionHeader("Friends")
                        ForEach(friends, id: \.0.id) { friendship, user in
                            NavigationLink { FriendDetailView(friend: user) } label: { friendCard(user) }
                        }
                    }

                    if friends.isEmpty && pendingRequests.isEmpty && !isLoading {
                        VStack(spacing: 12) {
                            Spacer().frame(height: 20)
                            Image(systemName: "person.badge.plus").font(.system(size: 44)).foregroundStyle(.tertiary)
                            Text("No friends yet").font(.system(size: 16, weight: .semibold)).foregroundStyle(.secondary)
                            Text("Tap + to find and add friends").font(.system(size: 13)).foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 140)
            }
            .scrollIndicators(.hidden)
            .refreshable { await loadFriends() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAddFriend = true } label: {
                        Image(systemName: "person.badge.plus").foregroundStyle(ArcTheme.action)
                    }
                }
            }
            .toolbarVisibility(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingAddFriend) {
                AddFriendSheet().presentationDetents([.medium, .large])
            }
            .task { await loadFriends() }
        }
    }

    private func loadFriends() async {
        isLoading = true; errorMessage = nil
        do {
            let friendships = try await supabase.getFriends()
            var loaded: [(ArcSupabase.Friendship, ArcSupabase.ArcUser)] = []
            for f in friendships {
                let friendId = f.requester_id == supabase.currentUser?.id ? f.addressee_id : f.requester_id
                if let profile = try? await supabase.getProfile(userId: friendId) {
                    loaded.append((f, profile))
                }
            }
            friends = loaded

            let pending = try await supabase.getPendingRequests()
            var loadedPending: [(ArcSupabase.Friendship, ArcSupabase.ArcUser)] = []
            for p in pending {
                if let profile = try? await supabase.getProfile(userId: p.requester_id) {
                    loadedPending.append((p, profile))
                }
            }
            pendingRequests = loadedPending
        } catch {
            errorMessage = "Couldn't load friends: \(error.localizedDescription)"
        }
        isLoading = false
    }

    // MARK: - Components

    private func profileCard(_ user: ArcSupabase.ArcUser) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "person.circle.fill").font(.system(size: 40)).foregroundStyle(ArcTheme.action)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.display_name.isEmpty ? "You" : user.display_name).font(.system(size: 15, weight: .semibold))
                if let handle = user.handle {
                    Text("@\(handle)").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let airport = user.home_airport {
                Text(airport).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(ArcTheme.action)
            }
        }
        .padding(14).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func friendCard(_ user: ArcSupabase.ArcUser) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "person.circle.fill").font(.system(size: 32)).foregroundStyle(ArcTheme.action.opacity(0.6))
            VStack(alignment: .leading, spacing: 2) {
                Text(user.display_name).font(.system(size: 15, weight: .semibold))
                if let handle = user.handle {
                    Text("@\(handle)").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.tertiary)
        }
        .padding(14).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func requestCard(friendship: ArcSupabase.Friendship, user: ArcSupabase.ArcUser) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "person.circle.fill").font(.system(size: 32)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.display_name).font(.system(size: 15, weight: .semibold))
                Text("Wants to be friends").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Accept") {
                Task {
                    try? await supabase.acceptFriendRequest(friendshipId: friendship.id)
                    await loadFriends()
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

// MARK: - Add Friend Sheet

struct AddFriendSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var supabase = ArcSupabase.shared
    @State private var searchText = ""
    @State private var results: [ArcSupabase.ArcUser] = []
    @State private var sentTo: Set<String> = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextField("Search by name or @handle", text: $searchText)
                    .font(.system(size: 16))
                    .padding(12)
                    .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                    .onChange(of: searchText) {
                        Task {
                            guard searchText.count >= 2 else { results = []; return }
                            results = (try? await supabase.searchUsers(query: searchText)) ?? []
                            results = results.filter { $0.id != supabase.currentUser?.id }
                        }
                    }

                ForEach(results, id: \.id) { user in
                    HStack {
                        Image(systemName: "person.circle.fill").font(.system(size: 32)).foregroundStyle(ArcTheme.action.opacity(0.6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.display_name).font(.system(size: 15, weight: .semibold))
                            if let handle = user.handle {
                                Text("@\(handle)").font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if sentTo.contains(user.id) {
                            Text("Sent").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        } else {
                            Button("Add") {
                                Task {
                                    try? await supabase.sendFriendRequest(to: user.id)
                                    sentTo.insert(user.id)
                                }
                            }
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(ArcTheme.action, in: Capsule())
                        }
                    }
                    .padding(12)
                }

                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 16)
            .navigationTitle("Add Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.foregroundStyle(ArcTheme.action)
                }
            }
        }
    }
}

// MARK: - Friend Detail

struct FriendDetailView: View {
    let friend: ArcSupabase.ArcUser
    @State private var flights: [ArcSupabase.SharedFlight] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    Image(systemName: "person.circle.fill").font(.system(size: 60)).foregroundStyle(ArcTheme.action)
                    Text(friend.display_name).font(.system(size: 22, weight: .bold))
                    if let handle = friend.handle {
                        Text("@\(handle)").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 24)

                if flights.isEmpty {
                    Text("No shared flights").font(.system(size: 15)).foregroundStyle(.tertiary).padding(.top, 24)
                } else {
                    ForEach(flights) { flight in friendFlightCard(flight) }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 24)
        }
        .navigationTitle(friend.display_name)
        .navigationBarTitleDisplayMode(.inline)
        .task { flights = (try? await ArcSupabase.shared.getFriendFlights(userId: friend.id)) ?? [] }
    }

    private func friendFlightCard(_ flight: ArcSupabase.SharedFlight) -> some View {
        VStack(spacing: 12) {
            HStack {
                Text(flight.departure_iata).font(.system(size: 16, weight: .semibold, design: .monospaced))
                Spacer()
                Text(flight.flight_number).font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                Text(flight.arrival_iata).font(.system(size: 16, weight: .semibold, design: .monospaced))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.separator)).frame(height: 3)
                    Capsule().fill(ArcTheme.action).frame(width: geo.size.width * flight.progress, height: 3)
                }
            }.frame(height: 3)
            HStack {
                Text(flight.status.capitalized).font(.system(size: 13, weight: .semibold))
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
