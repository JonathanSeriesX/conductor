import SwiftUI

struct SettingsView: View {
    @AppStorage("defaultSource") private var defaultSource = "assigned"
    @AppStorage("hideDoneInProjects") private var hideDone = false
    @AppStorage("notificationsEnabled") private var notifications = true
    @AppStorage("pollMinutes") private var pollMinutes = 3
    @AppStorage("checkForUpdates") private var checkForUpdates = true
    @Environment(Session.self) private var session

    var body: some View {
        Form {
            Section("Sidebar") {
                Picker("Open at launch", selection: $defaultSource) {
                    ForEach(Smart.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Hide Done issues in project lists", isOn: $hideDone)
                    .onChange(of: hideDone) { session.reloadTick += 1 }
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
                Button("Clear Cache and Spotlight Index") { DiskCache.clear() }
                Text("Issues you open or list are indexed for Spotlight and kept on disk so the app opens instantly.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
