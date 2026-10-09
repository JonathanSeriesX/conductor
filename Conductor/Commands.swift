import SwiftUI

/// What the issue page in the key window can do. The Issue menu reads it, so every action and its
/// shortcut is discoverable in the menu bar and works from any issue window.
struct IssueActions {
    enum Action: Hashable {
        case openInBrowser, openInWindow, copyLink, copyKey, copyMarkdown
        case assign, assignToMe, watch, remind
        case transition(String)
        case editSummary, editDescription, comment, attach, link, logWork, subtask, refresh
        case changeStatus, changePriority, editLabels
    }
    let key: String
    let watching: Bool
    let assignedToMe: Bool
    let transitions: [Transition]
    let canEditSummary: Bool
    let canEditDescription: Bool
    /// A summary, description or comment editor is open.
    let isEditing: Bool
    /// Set while the page can go back to the issue it came from.
    let back: (() -> Void)?
    /// In the main window's preview column; a window of its own already is the issue's window.
    let embedded: Bool
    let perform: (Action) -> Void
}

extension IssueActions: Equatable {
    /// Compared by what the menus show. Without this, every evaluation of the page published a "new" value (the
    /// closures), its window re-rendered on the focused value, which re-evaluated the page: 16 passes per load.
    static func == (a: Self, b: Self) -> Bool {
        a.key == b.key && a.watching == b.watching && a.assignedToMe == b.assignedToMe
            && a.transitions == b.transitions && a.canEditSummary == b.canEditSummary
            && a.canEditDescription == b.canEditDescription && a.isEditing == b.isEditing
            && (a.back == nil) == (b.back == nil) && a.embedded == b.embedded
    }
}

/// What the issue list in the key window can do.
struct ListActions {
    let saveFilter: (() -> Void)?
    let openBoard: (() -> Void)?
    let sort: Binding<ListFilters.Sort>?
}

extension FocusedValues {
    @Entry var issueActions: IssueActions?
    @Entry var listActions: ListActions?
}

/// Single-key shortcuts after Jira's or Linear's, on top of the ⌘ ones in the menus. They act while no text
/// field has the focus, so typing is never hijacked; that is why they are not menu key equivalents.
enum ShortcutScheme: String, CaseIterable {
    case mac, jira, linear

    static var current: ShortcutScheme {
        ShortcutScheme(rawValue: UserDefaults.standard.string(forKey: "shortcutScheme") ?? "") ?? .jira
    }

    var title: String {
        switch self {
        case .mac: "macOS"
        case .jira: "Jira"
        case .linear: "Linear"
        }
    }

    enum Key {
        case newIssue, search, issue(IssueActions.Action)
        var title: String {
            switch self {
            case .newIssue: String(localized: "New Issue…")
            case .search: String(localized: "Find Issues")
            case .issue(.editSummary): String(localized: "Edit Summary")
            case .issue(.assign): String(localized: "Assign…")
            case .issue(.assignToMe): String(localized: "Assign to Me")
            case .issue(.comment): String(localized: "Add Comment")
            case .issue(.watch): String(localized: "Watch This Issue")
            case .issue(.changeStatus): String(localized: "Change Status")
            case .issue(.changePriority): String(localized: "Priority")
            case .issue(.editLabels): String(localized: "Labels")
            case .issue(let a): String(describing: a)
            }
        }
    }

    /// ponytail: the keys each tool documents that map onto an action this app has; extend as needed.
    var keys: [(Character, Key)] {
        switch self {
        case .mac: []
        case .jira:
            [
                ("c", .newIssue), ("/", .search), ("e", .issue(.editSummary)), ("a", .issue(.assign)),
                ("i", .issue(.assignToMe)), ("m", .issue(.comment)), ("w", .issue(.watch)), ("l", .issue(.editLabels)),
            ]
        case .linear:
            [
                ("c", .newIssue), ("/", .search), ("a", .issue(.assign)), ("i", .issue(.assignToMe)),
                ("s", .issue(.changeStatus)), ("p", .issue(.changePriority)), ("l", .issue(.editLabels)),
            ]
        }
    }

    /// "c New Issue… · a Assign…", for Settings.
    var legend: String { keys.map { "\($0.0) \($0.1.title)" }.joined(separator: " · ") }

    /// Runs the key's action and swallows the event; hands back anything else, and everything while text is edited.
    @MainActor static func handle(_ e: NSEvent, issue: IssueActions?, session: Session) -> NSEvent? {
        guard e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
            !(e.window?.firstResponder is NSTextView), let ch = e.charactersIgnoringModifiers?.first,
            let key = current.keys.first(where: { $0.0 == ch })?.1
        else { return e }
        switch key {
        case .newIssue: session.createIssueRequested = true
        case .search: session.focusSearchRequested = true
        case .issue(let action):
            guard let issue else { return e }
            issue.perform(action)
        }
        return nil
    }
}

/// Menu bar commands that act on whatever the key window shows.
struct AppCommands: Commands {
    let session: Session
    @FocusedValue(\.issueActions) private var issue
    @FocusedValue(\.listActions) private var list
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .printItem) {}
        CommandMenu("Go") {
            Button("Assigned to Me") { go(.assigned) }.keyboardShortcut("1")
            Button("Reported by Me") { go(.reported) }.keyboardShortcut("2")
            Button("Recently Viewed") { go(.recent) }.keyboardShortcut("3")
            Button("Watching") { go(.watching) }.keyboardShortcut("4")
            Divider()
            Button("Reload") { session.reloadTick += 1 }.keyboardShortcut("r")
            Button("Refresh Projects") { Task { await session.refreshAll() } }
        }
        CommandGroup(after: .newItem) {
            Button("Save Filter…") { list?.saveFilter?() }
                .keyboardShortcut("s")
                .disabled(list?.saveFilter == nil)
        }
        CommandGroup(before: .windowList) {
            // Mail's "Message Viewer" ⌘0: the list window, after it was closed behind an issue window.
            Button("Issues") { showMain() }.keyboardShortcut("0")
            Divider()
        }
        CommandGroup(before: .sidebar) {
            Button("Open Board") { list?.openBoard?() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(list?.openBoard == nil)
            Divider()
            // Inline, as Mail's Sort By would be without its submenu.
            Section("Sort By") {
                SortMenuItems(sort: list?.sort ?? .constant(ListFilters.Sort())).disabled(list?.sort == nil)
            }
            Divider()
        }
        CommandMenu("Issue") {
            item("Open in Browser", .openInBrowser, "o", [.command, .shift])
            // A window group keeps one window per issue, so from an issue's own window there is nothing to open.
            item("Open in New Window", .openInWindow, "o").disabled(issue?.embedded != true)
            Divider()
            item("Copy Link", .copyLink, "c", [.command, .shift])
            item("Copy as Markdown", .copyMarkdown, "c", [.command, .option])
            item("Copy Key", .copyKey, "c", [.command, .control])
            Divider()
            // AppKit keeps a submenu item enabled whatever .disabled says; with nothing to offer it is a plain item.
            if let transitions = issue?.transitions, !transitions.isEmpty {
                Menu("Change Status") {
                    ForEach(transitions) { t in Button(t.name) { issue?.perform(.transition(t.id)) } }
                }
            } else {
                Button("Change Status") {}.disabled(true)
            }
            item("Assign…", .assign, "a", [.command, .shift])
            item("Assign to Me", .assignToMe, "i", [.command, .shift]).disabled(issue?.assignedToMe == true)
            item(issue?.watching == true ? "Stop Watching This Issue" : "Watch This Issue", .watch)
            item("Remind Me…", .remind, "r", [.command, .option])
            Divider()
            item("Edit Summary", .editSummary, "e").disabled(issue?.canEditSummary != true)
            item("Edit Description", .editDescription, "e", [.command, .option]).disabled(
                issue?.canEditDescription != true)
            item("Add Comment", .comment, "m", [.command, .shift])
            item("Attach Files…", .attach, "a", [.command, .option])
            item("Link Issue…", .link, "l", [.command, .shift])
            item("Log Work…", .logWork, "l", [.command, .option])
            item("Create Subtask…", .subtask, "n", [.command, .shift])
            Divider()
            item("Refresh Issue", .refresh, "r", [.command, .shift])
        }
    }

    private func go(_ smart: Smart) {
        session.navigationRequest = session.filters(for: smart)
        showMain()
    }

    /// Brings the list window to the front, making one when it was closed. Only an issue or board window
    /// may be open, and every list command needs the list.
    private func showMain() {
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }

    private func item(
        _ title: LocalizedStringKey, _ action: IssueActions.Action, _ key: KeyEquivalent? = nil,
        _ modifiers: EventModifiers = .command
    ) -> some View {
        Button(title) { issue?.perform(action) }
            .keyboardShortcut(key.map { KeyboardShortcut($0, modifiers: modifiers) })
            .disabled(issue == nil)
    }
}

/// An issue with its own back trail: the content of an issue window and of the main window's preview column.
struct IssueWindow: View {
    /// The window's value, or the main window's selection: a change from outside starts a fresh trail.
    @Binding var target: IssueTarget
    var embedded = false
    /// Issues this window showed before the current one, so a jump to a subtask or link can come back.
    @State private var trail: [IssueTarget] = []
    @State private var navigating = false
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @FocusedValue(\.issueActions) private var issueActions

    var body: some View {
        Group {
            if let st = session.state(target.accountID) {
                IssueDetailView(
                    target: target,
                    open: {
                        trail.append(target)
                        navigating = true
                        target = $0
                    },
                    back: trail.isEmpty
                        ? nil
                        : {
                            navigating = true
                            target = trail.removeLast()
                        }, embedded: embedded
                )
                .environment(\.jira, st)
            } else if session.isRestoring {
                ZStack {
                    Backdrop()
                    ProgressView()
                }
            } else {
                // A restored window whose account signed out, or one from a dev launch with a fresh account id.
                ContentUnavailableView {
                    Label("\(target.key) isn't available", systemImage: "person.crop.circle.badge.xmark")
                } description: {
                    Text("The account this issue belongs to is no longer signed in.")
                } actions: {
                    Button("Close") { dismiss() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Backdrop())
                // Signed out of every account: the window has nothing left to show. With other accounts still in,
                // it stays, so a restored window is not lost behind a sign-out of one account.
                .task { if !session.isSignedIn { dismiss() } }
            }
        }
        .writingToolsBehavior(.disabled)
        .onChange(of: target) {
            if !navigating { trail = [] }  // another row was picked: that is a new start, not a step
            navigating = false
        }
        .background(WindowCascader())
        // The main window's monitor covers the preview column; a window of its own needs one.
        .background(
            embedded
                ? nil
                : WindowEventMonitor(mask: .keyDown) { e in
                    // Escape in the comment box gives the keyboard up; editors with a Cancel keep theirs.
                    if e.keyCode == 53, e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                        issueActions?.isEditing != true, let tv = e.window?.firstResponder as? NSTextView,
                        !tv.isFieldEditor
                    {
                        e.window?.focusList()
                        return nil
                    }
                    return ShortcutScheme.handle(e, issue: issueActions, session: session)
                }
        )
    }
}

func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}

/// Offsets a new issue window from the one opened before it, as document windows do. SwiftUI puts every
/// window of a group at the same spot. A window the system restored keeps its own frame.
private struct WindowCascader: NSViewRepresentable {
    func makeNSView(context: Context) -> Cascader { Cascader() }
    func updateNSView(_ view: Cascader, context: Context) {}

    final class Cascader: NSView {
        private var done = false
        override func viewDidMoveToWindow() {
            guard !done, let window, let id = window.identifier?.rawValue, id.hasPrefix("issue") else { return }
            done = true
            let others = NSApp.windows.filter {
                $0 !== window && $0.isVisible && $0.identifier?.rawValue.hasPrefix("issue") == true
            }
            guard let last = others.max(by: { $0.orderedIndex > $1.orderedIndex }) else { return }
            if abs(last.frame.origin.x - window.frame.origin.x) < 2, abs(last.frame.maxY - window.frame.maxY) < 2 {
                window.setFrameTopLeftPoint(
                    window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
            }
        }
    }
}
