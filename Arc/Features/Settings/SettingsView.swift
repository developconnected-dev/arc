import SwiftUI
import SwiftData
import PhotosUI

struct SettingsView: View {
    @Query(sort: \Flight.scheduledDeparture) private var allFlights: [Flight]
    @ObservedObject private var supabase = ArcSupabase.shared
    @State private var exportURL: URL?
    @State private var profileName = ""
    @State private var profileRegion = Locale.current.region?.identifier ?? "CH"
    @State private var showRegionPicker = false
    @State private var pendingAvatar: String??   // .some(url)=new, .some(nil)=remove, nil=untouched
    @State private var photoPick: PhotosPickerItem?
    @State private var profileSaving = false
    @State private var profileSaved = false
    @State private var designEmoji = ""
    @State private var designColor = "#4DABF7"

    static let avatarEmojis = ["😎", "🥳", "🤠", "😺", "🦊", "🐻", "🐼", "🦁",
                               "🐨", "🐸", "🦄", "🐙", "🌞", "🌸", "🍀", "⚡️",
                               "✈️", "🌍", "🧳", "🏔️", "🌊", "🍉", "🎧", "🚀"]
    static let avatarColors = ["#FF6B6B", "#FFA94D", "#FFD43B", "#69DB7C",
                               "#38D9A9", "#4DABF7", "#9775FA", "#F783AC"]

    private func applyDesign() {
        guard !designEmoji.isEmpty else { return }
        pendingAvatar = .some(FriendAvatar.emojiAvatarString(emoji: designEmoji, colorHex: designColor))
    }
    @AppStorage("apiEndpoint") private var apiEndpoint = "https://your-worker.workers.dev"
    // The anon key is safe to ship in the client — Supabase's security model is
    // Postgres row-level security (see supabase/migrations/001_initial.sql),
    // not secrecy of this key. It's the same key every device/browser uses.
    @AppStorage("supabase_url") private var supabaseURL = "https://your-project-ref.supabase.co"
    @AppStorage("supabase_anon_key") private var supabaseAnonKey = "REDACTED_SUPABASE_ANON_KEY"
    @AppStorage("notifyGateChanges") private var notifyGateChanges = true
    @AppStorage("notifyDelays") private var notifyDelays = true
    @AppStorage("notifyLanding") private var notifyLanding = true
    @AppStorage("notifyDepartureReminder") private var notifyDepartureReminder = true
    @AppStorage("trackingInterval") private var trackingInterval = 60

    var body: some View {
        NavigationStack {
            List {
                // Profile — what friends see
                if supabase.isSignedIn {
                    Section {
                        HStack(spacing: 16) {
                            FriendAvatar(name: displayedName.isEmpty ? "You" : displayedName,
                                         size: 64, avatarURL: displayedAvatar)
                            VStack(alignment: .leading, spacing: 6) {
                                TextField("Your name", text: $profileName)
                                    .font(.system(size: 17, weight: .semibold))
                                Button {
                                    showRegionPicker = true
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(String.flag(forRegion: profileRegion))
                                        Text(Locale.current.localizedString(forRegionCode: profileRegion) ?? profileRegion)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(ArcTheme.action)
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)

                        // The avatar designer: an emoji face on a colored
                        // disc. Small feature, but it renders natively —
                        // crisp on every surface including map bubbles.
                        VStack(alignment: .leading, spacing: 12) {
                            Text("AVATAR").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary).tracking(0.6)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 30)), count: 6),
                                      spacing: 6) {
                                ForEach(Self.avatarEmojis, id: \.self) { emoji in
                                    Button {
                                        designEmoji = emoji
                                        applyDesign()
                                    } label: {
                                        Text(emoji).font(.system(size: 22))
                                            .frame(maxWidth: .infinity, minHeight: 34)
                                            .background(designEmoji == emoji ? ArcTheme.action.opacity(0.25) : .clear,
                                                        in: Circle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            HStack(spacing: 8) {
                                ForEach(Self.avatarColors, id: \.self) { hex in
                                    Button {
                                        designColor = hex
                                        applyDesign()
                                    } label: {
                                        Circle().fill(Color(hex: hex) ?? .gray)
                                            .frame(width: 24, height: 24)
                                            .overlay(Circle().stroke(.primary.opacity(designColor == hex ? 0.9 : 0),
                                                                     lineWidth: 2))
                                    }
                                    .buttonStyle(.plain)
                                }
                                Spacer(minLength: 0)
                            }
                            TextField("Or type any emoji", text: $designEmoji)
                                .font(.system(size: 18))
                                .multilineTextAlignment(.center)
                                .padding(.vertical, 6)
                                .background(Color(.secondarySystemFill), in: Capsule())
                                .onChange(of: designEmoji) { _, new in
                                    // Keep exactly the LAST character typed
                                    // (emoji are multi-scalar; suffix keeps
                                    // them whole).
                                    if new.count > 1 { designEmoji = String(new.suffix(1)) }
                                    if !designEmoji.isEmpty { applyDesign() }
                                }
                        }
                        .padding(.vertical, 4)

                        PhotosPicker(selection: $photoPick, matching: .images) {
                            Label("Use a Photo Instead", systemImage: "photo")
                                .font(.system(size: 15))
                        }

                        if displayedAvatar != nil {
                            Button("Remove Avatar", role: .destructive) {
                                pendingAvatar = .some(nil)
                            }
                            .font(.system(size: 15))
                        }

                        Button {
                            Task { await saveProfile() }
                        } label: {
                            HStack {
                                Text(profileSaving ? "Saving…" : profileSaved ? "Saved ✓" : "Save Profile")
                                    .font(.system(size: 15, weight: .semibold))
                                Spacer()
                            }
                        }
                        .disabled(profileSaving || !profileDirty)
                    } header: {
                        Text("Profile")
                    } footer: {
                        Text("Your name, passport, and avatar are what friends see in their app and on the map.")
                    }
                }

                // Notifications
                Section {
                    Toggle("Gate changes", isOn: $notifyGateChanges)
                    Toggle("Delays", isOn: $notifyDelays)
                    Toggle("Landing", isOn: $notifyLanding)
                    Toggle("2h departure reminder", isOn: $notifyDepartureReminder)
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Choose which flight events trigger notifications.")
                }

                // Tracking
                Section {
                    Picker("Update interval", selection: $trackingInterval) {
                        Text("30 seconds").tag(30)
                        Text("1 minute").tag(60)
                        Text("2 minutes").tag(120)
                        Text("5 minutes").tag(300)
                    }
                } header: {
                    Text("Live Tracking")
                } footer: {
                    Text("How often Arc checks for flight updates. Shorter intervals use more battery and API calls.")
                }

                // API
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Backend URL")
                            .font(ArcType.captionEmph)
                            .foregroundStyle(ArcColor.textMuted)
                        TextField("https://...", text: $apiEndpoint)
                            .font(ArcType.monoSmall)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("API")
                } footer: {
                    Text("This is the URL of your deployed Cloudflare Worker (backend/ folder). The AeroDataBox key itself is never entered here — it lives server-side as a Worker secret. See backend/wrangler.toml for the full deploy steps.")
                }

                // Supabase (Social)
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Supabase URL")
                            .font(ArcType.captionEmph)
                            .foregroundStyle(ArcColor.textMuted)
                        TextField("https://xyz.supabase.co", text: $supabaseURL)
                            .font(ArcType.monoSmall)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Anon Key")
                            .font(ArcType.captionEmph)
                            .foregroundStyle(ArcColor.textMuted)
                        SecureField("eyJ...", text: $supabaseAnonKey)
                            .font(ArcType.monoSmall)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Social (Supabase)")
                } footer: {
                    Text("Connect your Supabase project to enable Friends, Shared Journeys, and Watchers.")
                }

                // Account
                if ArcSupabase.shared.isSignedIn {
                    Section {
                        Button("Sign Out") {
                            ArcSupabase.shared.signOut()
                        }
                        .foregroundStyle(.red)
                    } header: {
                        Text("Account")
                    }
                }

                // About
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("0.1.0")
                            .foregroundStyle(ArcColor.textMuted)
                    }
                    HStack {
                        Text("Data source")
                        Spacer()
                        Text("AeroDataBox + OpenSky")
                            .foregroundStyle(ArcColor.textMuted)
                    }
                } header: {
                    Text("About")
                }

                // Data
                Section {
                    if allFlights.isEmpty {
                        Text("No flights to export yet")
                            .foregroundStyle(ArcColor.textMuted)
                    } else if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Share Export (\(allFlights.count) flights)", systemImage: "square.and.arrow.up")
                        }
                        .foregroundStyle(ArcColor.accent)
                    } else {
                        Button {
                            exportURL = FlightExporter.writeJSONFile(allFlights)
                        } label: {
                            Text("Export Flight Data (\(allFlights.count) flights)")
                        }
                        .foregroundStyle(ArcColor.accent)
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Exports every flight as JSON — your own data, ready to keep or move elsewhere.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(ArcColor.bg)
            .navigationTitle("Settings")
            .sheet(isPresented: $showRegionPicker) {
                NationalityPicker(selection: $profileRegion)
            }
            .onChange(of: photoPick) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data),
                       let url = FriendAvatar.makeDataURL(from: image) {
                        pendingAvatar = .some(url)
                    }
                    photoPick = nil
                }
            }
            .onAppear {
                if let user = supabase.currentUser {
                    profileName = user.display_name
                    if let nation = user.nationality { profileRegion = nation }
                }
            }
        }
    }

    // MARK: - Profile editing

    private var displayedName: String {
        profileName.isEmpty ? (supabase.currentUser?.display_name ?? "") : profileName
    }

    /// Pending edit wins; otherwise whatever the profile currently has.
    private var displayedAvatar: String? {
        if let pending = pendingAvatar { return pending }
        return supabase.currentUser?.avatar_url
    }

    private var profileDirty: Bool {
        guard let user = supabase.currentUser else { return false }
        return pendingAvatar != nil
            || profileName.trimmingCharacters(in: .whitespaces) != user.display_name
            || profileRegion != (user.nationality ?? "")
    }

    private func saveProfile() async {
        profileSaving = true
        profileSaved = false
        let name = profileName.trimmingCharacters(in: .whitespaces)
        try? await ArcSupabase.shared.updateProfile(
            displayName: name.isEmpty ? nil : name,
            nationality: profileRegion)
        if let pending = pendingAvatar {
            try? await ArcSupabase.shared.updateAvatar(dataURL: pending)
            pendingAvatar = nil
        }
        profileSaving = false
        profileSaved = true
    }
}
