import SwiftUI
import CoreSpotlight

struct BoardTarget: Hashable, Codable {
    let accountID: UUID
    let projectKey: String
}

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
            // Takes ⌘F away from the text-editing Find panel: in this app, Find means the issue search.
            CommandGroup(replacing: .textEditing) {
                Button("Find Issues") { session.focusSearchRequested = true }.keyboardShortcut("f")
            }
            CommandGroup(after: .appSettings) {
                Button("Check for Updates…") { UpdateChecker.shared.check(interactive: true) }
            }
            SidebarCommands()
            ToolbarCommands()
            AppCommands(session: session)
        }

        WindowGroup("Issue", id: "issue", for: IssueTarget.self) { $target in
            if let target { IssueWindow(target: target).environment(session) }
        }
        .defaultSize(width: 980, height: 820)

        WindowGroup("Board", id: "board", for: BoardTarget.self) { $target in
            if let target {
                BoardView(target: target).environment(session)
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
    @Environment(\.openSettings) private var openSettings
    @AppStorage("defaultSource") private var defaultSource = "assigned"
    @SceneStorage("source") private var storedSource = ""
    @SceneStorage("issue") private var storedIssue = ""
    @State private var source: Source?
    @State private var selected: IssueTarget?
    @State private var restored = false

    private var currentProject: (Project, AccountState)? {
        if case .project(let p, let id) = source, let st = session.state(id) { return (p, st) }
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
                        IssueListView(source: source, selection: $selected)
                            // Wide enough for every filter chip; at the default window size the issue page gets about half.
                            .navigationSplitViewColumnWidth(min: 360, ideal: 420)
                    }
                } detail: {
                    if let selected, let st = session.state(selected.accountID) {
                        IssueDetailView(target: selected, open: { self.selected = $0 })
                            .environment(\.jira, st)
                            .id(selected)
                            // Esc closes the issue, unless a text field wants it (search, comment draft).
                            .background(WindowEventMonitor(mask: .keyDown) { e in
                                guard e.keyCode == 53, !(e.window?.firstResponder is NSText) else { return e }
                                self.selected = nil
                                return nil
                            })
                    } else {
                        Image(systemName: "ticket").font(.system(size: 56)).foregroundStyle(.quaternary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Backdrop())
                            .toolbar(id: "issue") { NewIssueToolbarItem() }
                            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                    }
                }
                .sheet(isPresented: Bindable(session).createIssueRequested) {
                    CreateIssueView(defaultProject: currentProject) { selected = $0 }
                }
            } else {
                LoginView()
            }
        }
        // macOS 27 pins a Siri button beside the caret of every text view; hiding just the button has no effect there,
        // so Writing Tools goes off for the whole window (it reaches sheets through the environment).
        .writingToolsBehavior(.disabled)
        .onAppear { restoreOnce() }
        .onChange(of: session.states.count) { restoreOnce() }
        .onChange(of: session.isRestoring) { restoreOnce() }
        .onChange(of: source) { _, new in if let new { storedSource = new.id } }
        .onChange(of: selected) { _, new in
            storedIssue = new.map { "\($0.accountID.uuidString)|\($0.key)" } ?? ""
            if let new { session.recordView(new) }
        }
        .onChange(of: session.navigationRequest) { _, req in
            if let req { source = req; session.navigationRequest = nil }
        }
        .onChange(of: session.pendingOpen) { _, target in
            if let target { selected = target; session.pendingOpen = nil; NSApp.activate() }
        }
        .onOpenURL { session.open(url: $0) }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String { session.open(spotlightID: id) }
        }
        #if DEBUG
        .task {
            // CONDUCTOR_OPEN=KEY opens that issue in the first account; CONDUCTOR_SHOW=create|board:KEY opens a sheet or window.
            let env = ProcessInfo.processInfo.environment
            guard env["CONDUCTOR_OPEN"] != nil || env["CONDUCTOR_SHOW"] != nil else { return }
            while !session.isSignedIn { try? await Task.sleep(for: .milliseconds(200)) }
            try? await Task.sleep(for: .seconds(1))
            if let key = env["CONDUCTOR_OPEN"], let st = session.states.first { selected = IssueTarget(accountID: st.id, key: key) }
            if env["CONDUCTOR_SHOW"] == "create" { session.createIssueRequested = true }
            if env["CONDUCTOR_SHOW"] == "settings" { openSettings() }
            if let show = env["CONDUCTOR_SHOW"], show.hasPrefix("board:"), let st = session.states.first {
                openWindow(id: "board", value: BoardTarget(accountID: st.id, projectKey: String(show.dropFirst(6))))
            }
        }
        #endif
    }

    /// Puts the window back where it was, once the catalog can resolve project and filter ids.
    private func restoreOnce() {
        guard !session.isRestoring, session.isSignedIn else { return }
        if source == nil || !restored {
            restored = true
            source = session.source(for: storedSource) ?? Smart(rawValue: defaultSource).flatMap(session.source) ?? session.source(for: .assigned)
            let parts = storedIssue.split(separator: "|", maxSplits: 1).map(String.init)
            if selected == nil, parts.count == 2, let id = UUID(uuidString: parts[0]), session.state(id) != nil {
                selected = IssueTarget(accountID: id, key: parts[1])
            }
        }
        // Requests made before this window existed, e.g. from Spotlight or a notification after the window was closed.
        if let req = session.navigationRequest { source = req; session.navigationRequest = nil }
        if let t = session.pendingOpen { selected = t; session.pendingOpen = nil }
        // An account that signed out takes its list and issue with it.
        if let s = source, let id = s.accountID, session.state(id) == nil { source = session.source(for: .assigned) }
        if let sel = selected, session.state(sel.accountID) == nil { selected = nil }
    }
}
