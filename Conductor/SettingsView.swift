import SwiftUI

struct SettingsView: View {
    @AppStorage("defaultSource") private var defaultSource = "assigned"
    @AppStorage("hideDone") private var hideDone = true
    @AppStorage("notificationsEnabled") private var notifications = true
    @AppStorage("pollMinutes") private var pollMinutes = 3
    @AppStorage("checkForUpdates") private var checkForUpdates = true
    @Environment(Session.self) private var session
    @State private var cacheSize: Int64 = 0

    var body: some View {
        Form {
            Section("Sidebar") {
                Picker("Open at launch", selection: $defaultSource) {
                    ForEach(Smart.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Hide Done issues by default", isOn: $hideDone)
                Text("New lists start on the Open status chip; switch any list to Any status or Done from the chip.").font(.caption).foregroundStyle(.secondary)
                if !session.hiddenPresets.isEmpty {
                    Button("Show \(session.hiddenPresets.count) Hidden Sidebar Items") { session.showHiddenPresets() }
                }
            }
            Section("Notifications") {
                Toggle("Notify about assignments, comments and status changes", isOn: $notifications)
                Stepper("Check every \(pollMinutes) min", value: $pollMinutes, in: 1...30)
                    .disabled(!notifications)
                Text("Covers issues you are assigned to, reported or are watching, on every account.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Updates") {
                Toggle("Check for updates daily", isOn: $checkForUpdates)
                HStack {
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { UpdateChecker.shared.check(interactive: true) }
                }
            }
            Section("Search") {
                Button("Clear Recent Searches") { session.clearRecentSearches() }
                HStack {
                    Button("Clear Cache and Spotlight Index") { DiskCache.clear(); cacheSize = 0 }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file)).foregroundStyle(.secondary)
                }
                .task { cacheSize = await DiskCache.size() }
                Text("Issues you open or list are indexed for Spotlight and kept on disk so the app opens instantly.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
