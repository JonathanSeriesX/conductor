import SwiftUI

/// What the issue page in the key window can do. The Issue menu reads it, so every action and its
/// shortcut is discoverable in the menu bar and works from any issue window.
struct IssueActions {
    enum Action: Hashable {
        case openInBrowser, openInWindow, copyLink, copyKey, copyMarkdown
        case assign, assignToMe, watch, star, remind, transition(String)
        case editSummary, editDescription, comment, attach, link, logWork, subtask, refresh
    }
    let key: String
    let watching: Bool
    let starred: Bool
    let assignedToMe: Bool
    let transitions: [Transition]
    let canEditSummary: Bool
    let canEditDescription: Bool
    let perform: (Action) -> Void
}

/// What the issue list in the key window can do.
struct ListActions {
    let saveFilter: (() -> Void)?
    let openBoard: (() -> Void)?
}

extension FocusedValues {
    @Entry var issueActions: IssueActions?
    @Entry var listActions: ListActions?
}

/// Menu bar commands that act on whatever the key window shows.
struct AppCommands: Commands {
    let session: Session
    @FocusedValue(\.issueActions) private var issue
    @FocusedValue(\.listActions) private var list
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .printItem) {}
        CommandGroup(before: .toolbar) {
            Button("Command Palette…") { palette(">") }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
        }
        CommandMenu("Go") {
            Button("Go to Issue, List or Project…") { palette("") }.keyboardShortcut("p")
            Divider()
            Button("Assigned to Me") { session.navigationRequest = session.source(for: .assigned) }.keyboardShortcut("1")
            Button("Reported by Me") { session.navigationRequest = session.source(for: .reported) }.keyboardShortcut("2")
            Button("Recently Viewed") { session.navigationRequest = session.source(for: .recent) }.keyboardShortcut("3")
            Button("Watching") { session.navigationRequest = session.source(for: .watching) }.keyboardShortcut("4")
            Button("Starred") { session.navigationRequest = .starred }.disabled(session.stars.isEmpty)
            Divider()
            Button("Reload") { session.reloadTick += 1 }.keyboardShortcut("r")
            Button("Refresh Projects") { Task { await session.refreshAll() } }
        }
        CommandGroup(after: .newItem) {
            Button("Save Search as Filter…") { list?.saveFilter?() }
                .keyboardShortcut("s")
                .disabled(list?.saveFilter == nil)
        }
        CommandGroup(before: .sidebar) {
            Button("Open Board") { list?.openBoard?() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(list?.openBoard == nil)
            Divider()
        }
        CommandMenu("Issue") {
            item("Open in Browser", .openInBrowser, "o", [.command, .shift])
            item("Open in New Window", .openInWindow, "o")
            Divider()
            item("Copy Link", .copyLink, "c", [.command, .shift])
            item("Copy as Markdown", .copyMarkdown, "c", [.command, .option])
            item("Copy Key", .copyKey, "c", [.command, .control])
            Divider()
            Menu("Change Status") {
                ForEach(issue?.transitions ?? []) { t in Button(t.name) { issue?.perform(.transition(t.id)) } }
            }
            .disabled(issue?.transitions.isEmpty ?? true)
            item("Assign…", .assign, "a", [.command, .shift])
            item("Assign to Me", .assignToMe, "i", [.command, .shift]).disabled(issue?.assignedToMe == true)
            item(issue?.watching == true ? "Stop Watching This Issue" : "Watch This Issue", .watch)
            item(issue?.starred == true ? "Unstar Issue" : "Star Issue", .star, "d")
            item("Remind Me…", .remind, "r", [.command, .option])
            Divider()
            item("Edit Summary", .editSummary, "e").disabled(issue?.canEditSummary != true)
            item("Edit Description", .editDescription, "e", [.command, .option]).disabled(issue?.canEditDescription != true)
            item("Add Comment", .comment, "m", [.command, .shift])
            item("Attach Files…", .attach, "a", [.command, .option])
            item("Link Issue…", .link, "l", [.command, .shift])
            item("Log Work…", .logWork, "l", [.command, .option])
            item("Create Subtask…", .subtask, "n", [.command, .shift])
            Divider()
            item("Refresh Issue", .refresh, "r", [.command, .shift])
        }
    }

    /// The palette becomes the key window, so it takes this window's actions along.
    private func palette(_ mode: String) {
        guard session.isSignedIn else { return }
        session.paletteMode = mode
        session.paletteIssue = issue
        session.paletteList = list
        openWindow(id: "palette")
    }

    private func item(_ title: String, _ action: IssueActions.Action, _ key: KeyEquivalent? = nil, _ modifiers: EventModifiers = .command) -> some View {
        Button(title) { issue?.perform(action) }
            .keyboardShortcut(key.map { KeyboardShortcut($0, modifiers: modifiers) })
            .disabled(issue == nil)
    }
}

/// An issue in a window of its own, so two can sit side by side. Links inside it navigate in place.
struct IssueWindow: View {
    @State var target: IssueTarget
    @Environment(Session.self) private var session

    var body: some View {
        Group {
            if let st = session.state(target.accountID) {
                IssueDetailView(target: target, open: { target = $0 })
                    .environment(\.jira, st)
                    .id(target)
            } else {
                ZStack { Backdrop(); ProgressView() }
            }
        }
        .writingToolsBehavior(.disabled)
        .frame(minWidth: 640, minHeight: 480)
        .onChange(of: target, initial: true) { session.recordView(target) }
    }
}

/// The menu bar extra: starred issues and how much is assigned to me on each account.
struct MenuBarMenu: View {
    @Environment(Session.self) private var session
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let starred = session.starredTargets
        if !starred.isEmpty {
            Section("Starred") {
                ForEach(starred, id: \.target) { s in
                    Button("\(s.target.key)  \(s.summary)") { show { session.pendingOpen = s.target } }
                }
            }
        }
        Section("Assigned to Me") {
            ForEach(session.states) { st in
                let count = st.assignedCount.map { "\($0)\(st.assignedMore ? "+" : "")" } ?? "–"
                Button("\(st.title)    \(count)") { show { session.navigationRequest = .smart(.assigned, st.id) } }
            }
        }
        Divider()
        Button("New Issue…") { show { session.createIssueRequested = true } }
        Button("Open Conductor") { show {} }
        Divider()
        Button("Quit Conductor") { NSApp.terminate(nil) }
    }

    private func show(_ request: () -> Void) {
        request()
        bringMainWindowForward(openWindow)
    }
}

func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}
