import SwiftUI
import SwiftData

struct SettingsView: View {
    @Query(sort: \Flight.scheduledDeparture) private var allFlights: [Flight]
    @State private var exportURL: URL?
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
        }
    }
}
