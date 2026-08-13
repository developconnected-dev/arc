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
    @AppStorage("notifyGateChanges") private var notifyGateChanges = true
    @AppStorage("notifyDelays") private var notifyDelays = true
    @AppStorage("notifyLanding") private var notifyLanding = true
    @AppStorage("notifyDepartureReminder") private var notifyDepartureReminder = true
    @AppStorage("trackingInterval") private var trackingInterval = 60

    /// Kept identical to FlightAPIClient's fallback, so "reset" really restores
    /// the shipping backend rather than a second, drifting copy of the URL.
    static let defaultEndpoint = "https://arc-backend.owncalai.workers.dev"
    @AppStorage("apiEndpoint") private var apiEndpoint = SettingsView.defaultEndpoint

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

                        HStack(spacing: 10) {
                            PhotosPicker(selection: $photoPick, matching: .images) {
                                Label("Use a Photo", systemImage: "photo")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 11)
                                    .background(ArcTheme.action.opacity(0.14), in: Capsule())
                                    .foregroundStyle(ArcTheme.action)
                            }
                            .buttonStyle(.plain)
                            if displayedAvatar != nil {
                                Button {
                                    pendingAvatar = .some(nil)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                        .font(.system(size: 14, weight: .semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 11)
                                        .background(ArcTheme.late.opacity(0.14), in: Capsule())
                                        .foregroundStyle(ArcTheme.late)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .listRowSeparator(.hidden)

                        Button {
                            Task { await saveProfile() }
                        } label: {
                            Text(profileSaving ? "Saving…" : profileSaved ? "Saved ✓" : "Save Profile")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background((profileSaving || !profileDirty) ? Color(.systemGray4) : ArcTheme.action,
                                            in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .disabled(profileSaving || !profileDirty)
                        .listRowSeparator(.hidden)
                    } header: {
                        Text("Profile")
                    } footer: {
                        Text("Your name, passport, and avatar are what friends see in their app and on the map.")
                    }
                }

                // Per-friend notification levels now live beside the friends
                // themselves, in Friends → Manage.

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

                // Account
                if ArcSupabase.shared.isSignedIn {
                    Section {
                        Button {
                            ArcSupabase.shared.signOut()
                        } label: {
                            Text("Sign Out")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(ArcTheme.late.opacity(0.14), in: Capsule())
                                .foregroundStyle(ArcTheme.late)
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
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
                        Text("AeroDataBox · Transitous · Ferryhopper")
                            .foregroundStyle(ArcColor.textMuted)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("About")
                }

                // Backend — so a local `wrangler dev` can be tested against
                // before anything is deployed.
                Section {
                    TextField("https://…", text: $apiEndpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.system(size: 14, design: .monospaced))
                    if apiEndpoint != Self.defaultEndpoint {
                        Button("Reset to default") { apiEndpoint = Self.defaultEndpoint }
                            .font(.system(size: 14))
                    }
                } header: {
                    Text("Backend")
                } footer: {
                    Text("Point Arc at a local worker while testing — `http://localhost:8799` when `wrangler dev` is running. Takes effect on the next search.")
                }

                // Data
                Section {
                    if allFlights.isEmpty {
                        Text("No flights to export yet")
                            .foregroundStyle(ArcColor.textMuted)
                    } else if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Share Export (\(allFlights.count) flights)", systemImage: "square.and.arrow.up")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(ArcTheme.action.opacity(0.14), in: Capsule())
                                .foregroundStyle(ArcTheme.action)
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                    } else {
                        Button {
                            exportURL = FlightExporter.writeJSONFile(allFlights)
                        } label: {
                            Text("Export Flight Data (\(allFlights.count) flights)")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(ArcTheme.action.opacity(0.14), in: Capsule())
                                .foregroundStyle(ArcTheme.action)
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
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
            .onAppear { seedProfileFields() }
            // The session bootstrap may still be loading the profile when
            // Settings opens — seed again when it lands (only untouched
            // fields, so an edit in progress is never clobbered).
            .onChange(of: supabase.currentUser?.id) { _, _ in seedProfileFields() }
        }
    }

    // MARK: - Profile editing

    private func seedProfileFields() {
        guard let user = supabase.currentUser else { return }
        if profileName.isEmpty { profileName = user.display_name }
        if let nation = user.nationality { profileRegion = nation }
    }

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
