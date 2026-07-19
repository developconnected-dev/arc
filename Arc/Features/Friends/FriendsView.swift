import SwiftUI

struct FriendsTabView: View {
    @ObservedObject private var supabase = ArcSupabase.shared

    var body: some View {
        NavigationStack {
            Group {
                if !supabase.isConfigured {
                    setupPrompt
                } else if !supabase.isSignedIn {
                    signInPrompt
                } else {
                    FriendsListView()
                }
            }
            .background(ArcColor.bg)
            .navigationTitle("Friends")
        }
    }

    private var setupPrompt: some View {
        VStack(spacing: ArcSpace.xl) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 60))
                .foregroundStyle(ArcColor.accent)
            Text("Set Up Social")
                .font(ArcType.heroSmall)
                .foregroundStyle(ArcColor.text)
            Text("To use Friends and Shared Journeys, connect your Supabase project in Settings.")
                .font(ArcType.body)
                .foregroundStyle(ArcColor.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var signInPrompt: some View {
        VStack(spacing: ArcSpace.xl) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 60))
                .foregroundStyle(ArcColor.accent)
            Text("Sign In")
                .font(ArcType.heroSmall)
                .foregroundStyle(ArcColor.text)
            Text("Sign in to share flights, track friends, and create live journey links.")
                .font(ArcType.body)
                .foregroundStyle(ArcColor.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            AppleSignInButton()
                .frame(height: 50)
                .frame(maxWidth: 280)
                .cornerRadius(ArcRadius.button)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sign In With Apple

import AuthenticationServices
import CryptoKit

struct AppleSignInButton: View {
    @ObservedObject private var supabase = ArcSupabase.shared

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
                        try? await supabase.signInWithApple(idToken: tokenString, nonce: nonce)
                    }
                }
            case .failure:
                break
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

struct FriendsListView: View {
    @ObservedObject private var supabase = ArcSupabase.shared
    @State private var friends: [(ArcSupabase.Friendship, ArcSupabase.ArcUser)] = []
    @State private var pendingRequests: [(ArcSupabase.Friendship, ArcSupabase.ArcUser)] = []
    @State private var showingAddFriend = false
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(spacing: ArcSpace.l) {
                // Profile card
                if let user = supabase.currentUser {
                    profileCard(user)
                }

                // Pending requests
                if !pendingRequests.isEmpty {
                    sectionHeader("Friend Requests")
                    ForEach(pendingRequests, id: \.0.id) { friendship, user in
                        requestCard(friendship: friendship, user: user)
                    }
                }

                // Friends
                if !friends.isEmpty {
                    sectionHeader("Friends")
                    ForEach(friends, id: \.0.id) { friendship, user in
                        NavigationLink {
                            FriendDetailView(friend: user)
                        } label: {
                            friendCard(user)
                        }
                    }
                }

                if friends.isEmpty && pendingRequests.isEmpty && !isLoading {
                    VStack(spacing: ArcSpace.l) {
                        Spacer().frame(height: 20)
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 48))
                            .foregroundStyle(ArcColor.accent.opacity(0.4))
                        Text("No friends yet")
                            .font(ArcType.bodyEmph)
                            .foregroundStyle(ArcColor.textMuted)
                        Text("Tap + to find and add friends")
                            .font(ArcType.caption)
                            .foregroundStyle(ArcColor.textDim)
                    }
                }
            }
            .padding(.horizontal, ArcSpace.screen)
            .padding(.bottom, ArcSpace.xl)
        }
        .refreshable { await loadFriends() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAddFriend = true } label: {
                    Image(systemName: "person.badge.plus")
                        .foregroundStyle(ArcColor.accent)
                }
            }
        }
        .sheet(isPresented: $showingAddFriend) {
            AddFriendSheet()
                .presentationDetents([.medium, .large])
                .presentationBackground(ArcColor.card)
        }
        .task { await loadFriends() }
    }

    private func loadFriends() async {
        isLoading = true
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
        } catch {}
        isLoading = false
    }

    // MARK: - Components

    private func profileCard(_ user: ArcSupabase.ArcUser) -> some View {
        HStack(spacing: ArcSpace.l) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(ArcColor.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.display_name.isEmpty ? "You" : user.display_name)
                    .font(ArcType.bodyEmph)
                    .foregroundStyle(ArcColor.text)
                if let handle = user.handle {
                    Text("@\(handle)")
                        .font(ArcType.caption)
                        .foregroundStyle(ArcColor.textMuted)
                }
            }
            Spacer()
            if let airport = user.home_airport {
                Text(airport)
                    .font(ArcType.monoSmall)
                    .foregroundStyle(ArcColor.accent)
            }
        }
        .padding(ArcSpace.l)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ArcRadius.card))
    }

    private func friendCard(_ user: ArcSupabase.ArcUser) -> some View {
        HStack(spacing: ArcSpace.l) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(ArcColor.accent.opacity(0.6))
            VStack(alignment: .leading, spacing: 2) {
                Text(user.display_name)
                    .font(ArcType.bodyEmph)
                    .foregroundStyle(ArcColor.text)
                if let handle = user.handle {
                    Text("@\(handle)")
                        .font(ArcType.caption)
                        .foregroundStyle(ArcColor.textMuted)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12))
                .foregroundStyle(ArcColor.textDim)
        }
        .padding(ArcSpace.l)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ArcRadius.card))
    }

    private func requestCard(friendship: ArcSupabase.Friendship, user: ArcSupabase.ArcUser) -> some View {
        HStack(spacing: ArcSpace.l) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(ArcColor.delayed)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.display_name)
                    .font(ArcType.bodyEmph)
                    .foregroundStyle(ArcColor.text)
                Text("Wants to be friends")
                    .font(ArcType.caption)
                    .foregroundStyle(ArcColor.textMuted)
            }
            Spacer()
            Button("Accept") {
                Task {
                    try? await supabase.acceptFriendRequest(friendshipId: friendship.id)
                    await loadFriends()
                }
            }
            .font(ArcType.captionEmph)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(ArcColor.accent, in: Capsule())
        }
        .padding(ArcSpace.l)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ArcRadius.card))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(ArcType.captionEmph)
            .foregroundStyle(ArcColor.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textCase(.uppercase)
            .tracking(0.8)
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
            VStack(spacing: ArcSpace.l) {
                TextField("Search by name or @handle", text: $searchText)
                    .font(ArcType.body)
                    .foregroundStyle(ArcColor.text)
                    .padding(ArcSpace.m)
                    .background(ArcColor.bg, in: RoundedRectangle(cornerRadius: ArcRadius.button))
                    .overlay(RoundedRectangle(cornerRadius: ArcRadius.button).strokeBorder(ArcColor.border))
                    .onChange(of: searchText) {
                        Task {
                            guard searchText.count >= 2 else { results = []; return }
                            results = (try? await supabase.searchUsers(query: searchText)) ?? []
                            // Filter out self
                            results = results.filter { $0.id != supabase.currentUser?.id }
                        }
                    }

                ForEach(results, id: \.id) { user in
                    HStack {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(ArcColor.accent.opacity(0.6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.display_name)
                                .font(ArcType.bodyEmph)
                                .foregroundStyle(ArcColor.text)
                            if let handle = user.handle {
                                Text("@\(handle)")
                                    .font(ArcType.caption)
                                    .foregroundStyle(ArcColor.textMuted)
                            }
                        }
                        Spacer()
                        if sentTo.contains(user.id) {
                            Text("Sent")
                                .font(ArcType.captionEmph)
                                .foregroundStyle(ArcColor.textMuted)
                        } else {
                            Button("Add") {
                                Task {
                                    try? await supabase.sendFriendRequest(to: user.id)
                                    sentTo.insert(user.id)
                                }
                            }
                            .font(ArcType.captionEmph)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(ArcColor.accent, in: Capsule())
                        }
                    }
                    .padding(ArcSpace.m)
                }

                Spacer()
            }
            .padding(.horizontal, ArcSpace.screen)
            .padding(.top, ArcSpace.l)
            .navigationTitle("Add Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(ArcColor.accent)
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
            VStack(spacing: ArcSpace.l) {
                // Friend header
                VStack(spacing: ArcSpace.s) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(ArcColor.accent)
                    Text(friend.display_name)
                        .font(ArcType.heroSmall)
                        .foregroundStyle(ArcColor.text)
                    if let handle = friend.handle {
                        Text("@\(handle)")
                            .font(ArcType.caption)
                            .foregroundStyle(ArcColor.textMuted)
                    }
                }
                .padding(.top, ArcSpace.xl)

                // Friend's flights
                if flights.isEmpty {
                    Text("No shared flights")
                        .font(ArcType.body)
                        .foregroundStyle(ArcColor.textDim)
                        .padding(.top, ArcSpace.xl)
                } else {
                    ForEach(flights) { flight in
                        friendFlightCard(flight)
                    }
                }
            }
            .padding(.horizontal, ArcSpace.screen)
            .padding(.bottom, ArcSpace.xl)
        }
        .background(ArcColor.bg)
        .navigationTitle(friend.display_name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            flights = (try? await ArcSupabase.shared.getFriendFlights(userId: friend.id)) ?? []
        }
    }

    private func friendFlightCard(_ flight: ArcSupabase.SharedFlight) -> some View {
        VStack(spacing: ArcSpace.m) {
            HStack {
                Text(flight.departure_iata)
                    .font(ArcType.mono)
                    .foregroundStyle(ArcColor.text)
                Spacer()
                Text(flight.flight_number)
                    .font(ArcType.caption)
                    .foregroundStyle(ArcColor.textMuted)
                Spacer()
                Text(flight.arrival_iata)
                    .font(ArcType.mono)
                    .foregroundStyle(ArcColor.text)
            }

            // Progress
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(ArcColor.border).frame(height: 3)
                    Capsule().fill(ArcColor.accent)
                        .frame(width: geo.size.width * flight.progress, height: 3)
                }
            }
            .frame(height: 3)

            HStack {
                Text(flight.status.capitalized)
                    .font(ArcType.captionEmph)
                    .foregroundStyle(flight.delay_minutes > 0 ? ArcColor.delayed : ArcColor.onTime)
                Spacer()
                if flight.delay_minutes > 0 {
                    Text("+\(flight.delay_minutes)m")
                        .font(ArcType.captionEmph)
                        .foregroundStyle(ArcColor.delayed)
                }
            }
        }
        .padding(ArcSpace.l)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ArcRadius.card))
    }
}
