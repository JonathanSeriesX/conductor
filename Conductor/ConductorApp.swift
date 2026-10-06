import SwiftUI

@main
struct ConductorApp: App {
    @State private var session = Session()

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(session)
                .task { await session.restore() }
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowToolbarStyle(.unified)
        // Always present a window at launch, even when restored state has none (e.g. after a test-host run).
        .defaultLaunchBehavior(.presented)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Sign Out…") { session.signOut() }
                    .disabled(!session.isSignedIn)
            }
        }
    }
}

struct RootView: View {
    @Environment(Session.self) private var session
    @State private var source: Source? = .assignedToMe
    #if DEBUG
    @State private var selectedKey: String? = ProcessInfo.processInfo.environment["CONDUCTOR_OPEN"]
    #else
    @State private var selectedKey: String?
    #endif

    var body: some View {
        Group {
        if session.isRestoring {
            ZStack { Backdrop(); ProgressView() }
        } else if session.isSignedIn {
            NavigationSplitView {
                SidebarView(selection: $source)
            } content: {
                if let source {
                    IssueListView(source: source, selection: $selectedKey)
                        .navigationSplitViewColumnWidth(min: 300, ideal: 380)
                }
            } detail: {
                if let selectedKey {
                    IssueDetailView(key: selectedKey, open: { self.selectedKey = $0 })
                        .id(selectedKey)
                } else {
                    ContentUnavailableView("Select an issue", systemImage: "ticket")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Backdrop())
                }
            }
            .id(session.active?.id) // different site, different projects: start the navigation over
        } else {
            LoginView()
        }
        }
        // Lives outside the re-identified split view so it survives the switch.
        .onChange(of: session.active?.id) { old, _ in
            if old != nil { source = .assignedToMe; selectedKey = nil }
        }
    }
}
