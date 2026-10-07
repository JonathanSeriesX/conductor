import SwiftUI

struct SettingsView: View {
    @AppStorage("defaultSource") private var defaultSource = "assigned"
    @AppStorage("hideDone") private var hideDone = true
    @AppStorage("notificationsEnabled") private var notifications = true
    @AppStorage("pollMinutes") private var pollMinutes = 3
    @AppStorage("checkForUpdates") private var checkForUpdates = true
    @AppStorage("backdrop") private var backdrop = "mesh"
    @Environment(Session.self) private var session

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Background", selection: $backdrop) {
                    Text("Aurora").tag("mesh")
                    Text("Aurora, muted").tag("muted")
                    Text("Dusk").tag("dusk")
                    Text("Forest").tag("forest")
                    Text("Plain").tag("plain")
                }
                HStack(spacing: 8) {
                    ForEach(["mesh", "muted", "dusk", "forest", "plain"], id: \.self) { style in
                        Button { backdrop = style } label: {
                            BackdropSwatch(style: style)
                                .frame(width: 54, height: 36)
                                .clipShape(.rect(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(backdrop == style ? Color.accentColor : .primary.opacity(0.15), lineWidth: backdrop == style ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("Plain follows the light or dark appearance of the window.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Sidebar") {
                Picker("Open at launch", selection: $defaultSource) {
                    ForEach(Smart.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Hide Done issues by default", isOn: $hideDone)
                Text("New lists start on the Open status chip; switch any list to Any status or Done from the chip.").font(.caption).foregroundStyle(.secondary)
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

/// A small preview of one backdrop style, independent of the stored setting.
private struct BackdropSwatch: View {
    let style: String
    var body: some View {
        Backdrop().environment(\.backdropOverride, style)
    }
}
