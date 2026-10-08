import CoreSpotlight
import SwiftUI

struct BoardTarget: Hashable, Codable {
    let accountID: UUID
    let projectKey: String
}

@main
struct ConductorApp: App {
    @State private var session = Session()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(session)
                .task {
                    await session.restore()
                    Notifier.shared.start(session)
                    UpdateChecker.shared.checkIfDue()
                }
                .frame(minWidth: 760, minHeight: 560)
        }
        .windowToolbarStyle(.unified)
        // Always present a window at launch, even when restored state has none (e.g. after a test-host run).
        .defaultLaunchBehavior(.presented)
        .defaultSize(width: 1400, height: 820)
        .handlesExternalEvents(matching: ["*"])
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Issue…") {
                    // The sheet hangs off the list window; make sure there is one.
                    if !NSApp.windows.contains(where: {
                        $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible
                    }) {
                        openWindow(id: "main")
                    }
                    session.createIssueRequested = true
                }
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
            CommandGroup(replacing: .help) {}  // there is no help book; the system item would only say so
            SidebarCommands()
            ToolbarCommands()
            AppCommands(session: session)
        }

        WindowGroup("Issue", id: "issue", for: IssueTarget.self) { $target in
            if let target { IssueWindow(target: target).environment(session).frame(minWidth: 640, minHeight: 480) }
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

/// Sidebar, the one list and a preview of the selected issue. Double-click opens an issue in a window of its own.
struct RootView: View {
    #if DEBUG
        @MainActor static var debugHooksRan = false
    #endif
    @Environment(Session.self) private var session
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage("defaultSource") private var defaultSource = "assigned"
    @SceneStorage("filters") private var storedFilters = ""
    @State private var filters = ListFilters()
    @State private var selection: IssueTarget?
    @FocusedValue(\.issueActions) private var issueActions
    @State private var restored = false

    private var currentProject: (Project, AccountState)? {
        guard let id = filters.account, let st = session.state(id), let key = filters.project,
            let p = st.projects.first(where: { $0.key == key })
        else { return nil }
        return (p, st)
    }

    var body: some View {
        Group {
            if session.isRestoring {
                ZStack {
                    Backdrop()
                    ProgressView()
                }
            } else if session.isSignedIn {
                NavigationSplitView {
                    SidebarView(
                        selection: Binding(
                            get: { session.preset(matching: filters)?.filters ?? filters },
                            set: { if let f = $0 { filters = f } }))
                } content: {
                    IssueListView(filters: $filters, selection: $selection)
                        .navigationSplitViewColumnWidth(min: 340, ideal: 420)
                } detail: {
                    if let selection {
                        IssueWindow(target: selection, embedded: true).id(selection)
                    } else {
                        ContentUnavailableView("No Issue Selected", systemImage: "doc.text")
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Backdrop())
                            // Without items of its own the column has no toolbar section, and the list's
                            // New Issue and Save Filter drift over here.
                            .toolbar(id: "empty") { ToolbarItem(id: "none") { EmptyView() }.glassTitle() }
                    }
                }
                .background(WindowEventMonitor(mask: .keyDown) { escape($0) })
                .sheet(isPresented: Bindable(session).createIssueRequested) {
                    CreateIssueView(defaultProject: currentProject) { openWindow(id: "issue", value: $0) }
                }
            } else {
                LoginView()
            }
        }
        // macOS 27 pins a Siri button beside the caret of every text view; hiding just the button has no effect there,
        // so Writing Tools goes off for the whole window (it reaches sheets through the environment).
        .writingToolsBehavior(.disabled)
        // Every URL lands in this window rather than opening another main window per link.
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .onAppear { restoreOnce() }
        .onChange(of: session.states.count) { restoreOnce() }
        .onChange(of: session.isRestoring) { restoreOnce() }
        .onChange(of: filters) { _, new in
            selection = nil  // another list: the preview would otherwise show an issue that is not in it
            storedFilters = (try? JSONEncoder().encode(new)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            session.lastFilters = new
        }
        .onChange(of: session.navigationRequest) { _, req in
            if let req {
                filters = req
                session.navigationRequest = nil
            }
        }
        .onChange(of: session.pendingOpen) { _, target in if let target { open(target) } }
        .onOpenURL { session.open(url: $0) }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                session.open(spotlightID: id)
            }
        }
        #if DEBUG
            .task {
                // CONDUCTOR_OPEN=KEY opens that issue in the first account; CONDUCTOR_SHOW=create|board:KEY opens a sheet or window.
                let env = ProcessInfo.processInfo.environment
                // Once per process: a new main window after closing one must not replay the launch request.
                guard env["CONDUCTOR_OPEN"] != nil || env["CONDUCTOR_SHOW"] != nil, !Self.debugHooksRan else { return }
                Self.debugHooksRan = true
                while !session.isSignedIn { try? await Task.sleep(for: .milliseconds(200)) }
                try? await Task.sleep(for: .seconds(1))
                if let key = env["CONDUCTOR_OPEN"], let st = session.states.first {
                    openWindow(id: "issue", value: IssueTarget(accountID: st.id, key: key))
                }
                if env["CONDUCTOR_SHOW"] == "create" { session.createIssueRequested = true }
                if env["CONDUCTOR_SHOW"] == "settings" { openSettings() }
                if let show = env["CONDUCTOR_SHOW"], show.hasPrefix("board:"), let st = session.states.first {
                    openWindow(id: "board", value: BoardTarget(accountID: st.id, projectKey: String(show.dropFirst(6))))
                }
            }
        #endif
    }

    /// Escape empties the preview column wherever the focus is, unless something nearer has a use for it: a field
    /// being edited cancels that edit, a search with text clears it, and a comment draft stays as it is.
    private func escape(_ e: NSEvent) -> NSEvent? {
        guard e.keyCode == 53, e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty, selection != nil
        else { return e }
        if issueActions?.isEditing == true { return e }
        // A popover's Escape arrives tagged with the main window on Tahoe; the popover (a child window) must close, not the preview.
        if NSApp.keyWindow !== e.window || e.window?.childWindows?.contains(where: \.isVisible) == true { return e }
        if let tv = e.window?.firstResponder as? NSTextView, !tv.string.isEmpty { return e }
        selection = nil
        return nil
    }

    /// Requests from Spotlight, notifications and links land in an issue window.
    private func open(_ target: IssueTarget) {
        openWindow(id: "issue", value: target)
        session.pendingOpen = nil
        NSApp.activate()
    }

    /// Puts the window back on the list it showed, once the accounts are known.
    private func restoreOnce() {
        guard !session.isRestoring, session.isSignedIn else { return }
        if !restored {
            restored = true
            // A window the system restored keeps its list; one opened with ⌘0 continues the last list; a launch
            // starts on the "Open at launch" list.
            if let data = storedFilters.data(using: .utf8),
                let f = try? JSONDecoder().decode(ListFilters.self, from: data),
                f.account.map({ session.state($0) != nil }) ?? true
            {
                filters = f
            } else if let f = session.lastFilters, f.account.map({ session.state($0) != nil }) ?? true {
                filters = f
            } else if let f = session.filters(for: Smart(rawValue: defaultSource) ?? .assigned) {
                filters = f
            }
        }
        // Requests made before this window existed, e.g. from Spotlight or a notification after the window was closed.
        if let req = session.navigationRequest {
            filters = req
            session.navigationRequest = nil
        }
        if let t = session.pendingOpen { open(t) }
        // An account that signed out takes its list with it.
        if let id = filters.account, session.state(id) == nil, let f = session.filters(for: .assigned) { filters = f }
    }
}
