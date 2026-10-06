import SwiftUI
import CoreSpotlight

@main
struct ConductorApp: App {
    @State private var session = Session()

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(session)
                .task {
                    await session.restore()
                    Notifier.shared.start(session)
                    UpdateChecker.shared.checkIfDue()
                }
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowToolbarStyle(.unified)
        // Always present a window at launch, even when restored state has none (e.g. after a test-host run).
        .defaultLaunchBehavior(.presented)
        .defaultSize(width: 1280, height: 820)
        .handlesExternalEvents(matching: ["*"])
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Issue…") { session.createIssueRequested = true }
                    .keyboardShortcut("n")
                    .disabled(!session.isSignedIn)
            }
            CommandMenu("Go") {
                Button("Assigned to Me") { session.navigationRequest = .assignedToMe }.keyboardShortcut("1")
                Button("Reported by Me") { session.navigationRequest = .reportedByMe }.keyboardShortcut("2")
                Button("Recently Viewed") { session.navigationRequest = .recent }.keyboardShortcut("3")
                Button("Watching") { session.navigationRequest = .watching }.keyboardShortcut("4")
                Divider()
                Button("Reload") { session.reloadTick += 1 }.keyboardShortcut("r")
            }
            // Takes ⌘F away from the text-editing Find panel: in this app, Find means the issue search.
            CommandGroup(replacing: .textEditing) {
                Button("Find Issues") { session.focusSearchRequested = true }.keyboardShortcut("f")
            }
            CommandGroup(after: .appSettings) {
                Button("Check for Updates…") { UpdateChecker.shared.check(interactive: true) }
                Divider()
                Button("Sign Out…") { session.signOut() }
                    .disabled(!session.isSignedIn)
            }
        }

        WindowGroup("Board", id: "board", for: String.self) { $projectKey in
            if let projectKey {
                BoardView(projectKey: projectKey).environment(session)
            }
        }
        .defaultSize(width: 1400, height: 820)

        Settings {
            SettingsView().environment(session)
        }
    }
}

struct RootView: View {
    @Environment(Session.self) private var session
    @Environment(\.openWindow) private var openWindow
    @AppStorage("defaultSource") private var defaultSource = "assigned"
    @SceneStorage("source") private var storedSource = ""
    @SceneStorage("issue") private var storedIssue = ""
    @State private var source: Source? = .assignedToMe
    @State private var restored = false
    #if DEBUG
    @State private var selectedKey: String? = ProcessInfo.processInfo.environment["CONDUCTOR_OPEN"]
    #else
    @State private var selectedKey: String?
    #endif

    private var currentProject: Project? {
        if case .project(let p) = source { return p }
        return nil
    }

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
                            .toolbar(id: "issue") { NewIssueToolbarItem() }
                    }
                }
                .id(session.active?.id) // different site, different projects: start the navigation over
                .sheet(isPresented: Bindable(session).createIssueRequested) {
                    CreateIssueView(defaultProject: currentProject) { selectedKey = $0 }
                }
            } else {
                LoginView()
            }
        }
        // Lives outside the re-identified split view so it survives the switch.
        .onChange(of: session.active?.id) { old, _ in
            if old != nil { source = session.source(for: defaultSource) ?? .assignedToMe; selectedKey = nil }
        }
        .onChange(of: session.projects.count) { restoreOnce() }
        .onChange(of: source) { _, new in if let new { storedSource = new.id } }
        .onChange(of: selectedKey) { _, new in storedIssue = new.map { "\(session.active?.site.host() ?? "")|\($0)" } ?? "" }
        .onChange(of: session.navigationRequest) { _, req in
            if let req { source = req; session.navigationRequest = nil }
        }
        .onChange(of: session.pendingOpen) { _, key in
            if let key { selectedKey = key; session.pendingOpen = nil; NSApp.activate() }
        }
        .onOpenURL { session.open(url: $0) }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String { session.open(spotlightID: id) }
        }
        #if DEBUG
        .task {
            // CONDUCTOR_SHOW=create opens the New Issue sheet; CONDUCTOR_SHOW=board:KEY opens a board window.
            guard let show = ProcessInfo.processInfo.environment["CONDUCTOR_SHOW"] else { return }
            while !session.isSignedIn { try? await Task.sleep(for: .milliseconds(200)) }
            try? await Task.sleep(for: .seconds(1))
            if show == "create" { session.createIssueRequested = true }
            if show.hasPrefix("board:") { openWindow(id: "board", value: String(show.dropFirst(6))) }
        }
        #endif
    }

    /// Puts the window back where it was, once the catalog can resolve project and filter ids.
    private func restoreOnce() {
        guard !restored, !session.projects.isEmpty else { return }
        restored = true
        if let s = session.source(for: storedSource.isEmpty ? defaultSource : storedSource) { source = s }
        let parts = storedIssue.split(separator: "|", maxSplits: 1).map(String.init)
        if selectedKey == nil, parts.count == 2, parts[0] == session.active?.site.host() { selectedKey = parts[1] }
    }
}
