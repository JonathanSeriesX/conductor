import SwiftUI

@main
struct ConductorApp: App {
    @State private var session = Session()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .task { await session.restore() }
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowToolbarStyle(.unified)
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
        } else {
            LoginView()
        }
    }
}
