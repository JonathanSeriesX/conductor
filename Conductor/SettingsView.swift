import SwiftUI

/// Tabs, as System Settings and Mail have them, so no pane is taller than the screen.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Accounts", systemImage: "person.crop.circle") { AccountSettings() }
            Tab("Notifications", systemImage: "bell") { NotificationSettings() }
            Tab("Advanced", systemImage: "slider.horizontal.3") { AdvancedSettings() }
        }
        .frame(width: 460, height: 420)  // the grouped forms scroll and report no height of their own
    }
}

private struct GeneralSettings: View {
    @AppStorage("defaultSource") private var defaultSource = "assigned"
    @AppStorage("hideDone") private var hideDone = true
    @Environment(Session.self) private var session
    /// The app's own AppleLanguages override, as System Settings › Language & Region › Applications writes it;
    /// empty follows the system. Read once: the picker, not the defaults, is the source while the pane is open.
    @State private var language =
        (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier!)?["AppleLanguages"]
        as? [String])?.first ?? ""
    /// Every language the app ships, by its own name, English first.
    private static let languages: [(code: String, name: String)] = {
        let codes = Bundle.main.localizations.filter { $0 != "Base" }
        let named = codes.map { code -> (code: String, name: String) in
            let name = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
            return (code, name.localizedCapitalized)
        }
        return named.sorted { a, b in a.code == "en" || (b.code != "en" && a.name < b.name) }
    }()

    var body: some View {
        Form {
            Section("Sidebar") {
                Picker("Open at launch", selection: $defaultSource) {
                    ForEach(Smart.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Hide Done issues by default", isOn: $hideDone)
                Text("New lists start on the Open status chip; switch any list to Any status or Done from the chip.")
                    .font(.caption).foregroundStyle(.secondary)
                if !session.hiddenPresets.isEmpty {
                    Button("Show \(session.hiddenPresets.count) Hidden Sidebar Items") { session.showHiddenPresets() }
                }
            }
            Section("Language") {
                Picker("Language", selection: $language) {
                    Text("System Default").tag("")
                    Divider()
                    ForEach(Self.languages, id: \.code) { Text(verbatim: $0.name).tag($0.code) }
                }
                .onChange(of: language) { _, code in
                    if code.isEmpty {
                        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                    } else {
                        UserDefaults.standard.set([code], forKey: "AppleLanguages")
                    }
                }
                HStack {
                    Text("Takes effect the next time Conductor opens.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Relaunch Now") {
                        let config = NSWorkspace.OpenConfiguration()
                        config.createsNewApplicationInstance = true
                        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
                            DispatchQueue.main.async { NSApp.terminate(nil) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Who is signed in, with the sidebar's Sign Out and Add Account in one place.
private struct AccountSettings: View {
    @Environment(Session.self) private var session
    @Environment(\.openWindow) private var openWindow
    @State private var signingOut: AccountState?

    var body: some View {
        Form {
            Section("Accounts") {
                ForEach(session.states) { st in
                    HStack {
                        Image(systemName: "circle.fill").foregroundStyle(st.color).imageScale(.small)
                        VStack(alignment: .leading) {
                            Text(st.title)
                            Text(verbatim: "\(st.account.email) · \(st.host)").font(.caption).foregroundStyle(
                                .secondary)
                        }
                        Spacer()
                        Button("Sign Out…") { signingOut = st }
                    }
                }
                // A window of its own in front of Settings: a sheet on the main window opened behind it (CON-272).
                // Signed out, the sign-in card is that window, and signing in there brings the main window.
                Button("Add Account…") { openWindow(id: session.isSignedIn ? "addAccount" : "login") }
            }
        }
        .formStyle(.grouped)
        .signOutDialog($signingOut, session: session)
    }
}

extension View {
    /// Asks before signing out of the account it is given: the sidebar and Settings both offer Sign Out.
    func signOutDialog(_ account: Binding<AccountState?>, session: Session) -> some View {
        confirmationDialog(
            "Sign out of \(account.wrappedValue?.title ?? "")?",
            isPresented: Binding(get: { account.wrappedValue != nil }, set: { if !$0 { account.wrappedValue = nil } }),
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                if let st = account.wrappedValue { session.remove(st.account) }
                account.wrappedValue = nil
            }
            Button("Cancel", role: .cancel) { account.wrappedValue = nil }
        } message: {
            Text("The token is removed from the Keychain. Cached issues stay until the cache is cleared.")
        }
    }
}

private struct NotificationSettings: View {
    @AppStorage("notificationsEnabled") private var notifications = true
    @AppStorage("pollMinutes") private var pollMinutes = 3

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Notify about assignments, comments and status changes", isOn: $notifications)
                Picker("Check every", selection: $pollMinutes) {
                    // The stored value stays on the list even when it is not one of the presets.
                    ForEach(Set([1, 2, 3, 5, 10, 15, 30] + [pollMinutes]).sorted(), id: \.self) { n in
                        Text(Duration.seconds(n * 60), format: .units(allowed: [.minutes], width: .wide)).tag(n)
                    }
                }
                .disabled(!notifications)
                Text("Covers issues you are assigned to, reported or are watching, on every account.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedSettings: View {
    @AppStorage("checkForUpdates") private var checkForUpdates = true
    @Environment(Session.self) private var session
    @State private var cacheSize: Int64 = 0

    var body: some View {
        Form {
            Section("Updates") {
                #if GITHUB_BUILD
                    Toggle("Check for updates daily", isOn: $checkForUpdates)
                #endif
                HStack {
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    #if GITHUB_BUILD
                        Button("Check Now") { UpdateChecker.shared.check(interactive: true) }
                    #endif
                }
            }
            Section("Search") {
                Button("Clear Recent Searches") { session.clearRecentSearches() }
                HStack {
                    Button("Clear Cache and Spotlight Index") {
                        DiskCache.clear()
                        cacheSize = 0
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file)).foregroundStyle(
                        .secondary)
                }
                .task { cacheSize = await DiskCache.size() }
                Text("Issues you open or list are indexed for Spotlight and kept on disk so the app opens instantly.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
