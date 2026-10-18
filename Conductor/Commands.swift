import SwiftUI

/// What the issue page in the key window can do. The Issue menu reads it, so every action and its
/// shortcut is discoverable in the menu bar and works from any issue window.
struct IssueActions {
    enum Action: Hashable {
        case openInBrowser, openInWindow, copyLink
        case assign, assignToMe, watch, remind
        case transition(String)
        case editSummary, editDescription, comment, attach, link, logWork, subtask, clone, refresh, history
        case changeStatus, changePriority, editLabels
    }
    let key: String
    let watching: Bool
    /// I unassigns the issue then, rather than assigning me.
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

extension IssueActions {
    /// Never true while me is unknown: an unassigned issue is nobody's.
    static func isMine(assignee: String?, me: String?) -> Bool { assignee != nil && assignee == me }
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

extension ListActions: Equatable {
    /// By what the menus show; the closures are new on every list pass, and publishing them each time made
    /// SwiftUI warn that the focused value changed several times per frame.
    static func == (a: Self, b: Self) -> Bool {
        (a.saveFilter == nil) == (b.saveFilter == nil) && (a.openBoard == nil) == (b.openBoard == nil)
            && a.sort?.wrappedValue == b.sort?.wrappedValue
    }
}

extension FocusedValues {
    @Entry var issueActions: IssueActions?
    @Entry var listActions: ListActions?
    /// The links of the issues picked in the key window's list or board, for ⇧⌘C; nil when the issue page's own
    /// key is the one to copy (a single row, whose page the preview shows).
    @Entry var selectedLinks: [URL]?
}

/// Jira's single keys on top of the ⌘ ones in the menus. They act while no text field has the focus, so typing
/// is never hijacked; that is why they are not menu key equivalents.
enum Shortcuts {
    enum Key: Equatable { case newIssue, search, issue(IssueActions.Action) }

    /// ponytail: the keys Jira documents that map onto an action this app has; extend as needed.
    static let keys: [(Character, Key)] = [
        ("c", .newIssue), ("/", .search), ("e", .issue(.editSummary)), ("a", .issue(.assign)),
        ("i", .issue(.assignToMe)), ("m", .issue(.comment)), ("w", .issue(.watch)), ("l", .issue(.editLabels)),
    ]

    /// The Issue menu's ⌘ shortcuts (mirrors AppCommands) for the actions Jira gives no single key.
    private static let menuKeys: [IssueActions.Action: String] = [
        .editDescription: "⌥⌘E", .attach: "⌥⌘A", .link: "⇧⌘L", .logWork: "⌥⌘L", .subtask: "⇧⌘N", .remind: "⌥⌘R",
    ]

    /// "M", "W", "⌥⌘E": what a caption tells the user to press for `action`; nil when nothing is bound.
    static func hint(for action: IssueActions.Action) -> String? {
        keys.first { $0.1 == .issue(action) }.map { String($0.0).uppercased() } ?? menuKeys[action]
    }

    /// The Issue menu lists the single keys as key equivalents, and a bare key equivalent would beat the text
    /// view being typed into (in any window: a picker popover's search field too). Typed into a text view, the
    /// key goes straight to it, past the menu.
    @MainActor static func guardTyping() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                let tv = e.window?.firstResponder as? NSTextView, let ch = e.charactersIgnoringModifiers?.first,
                keys.contains(where: { $0.0 == ch })
            else { return e }
            tv.keyDown(with: e)
            return nil
        }
    }

    /// Runs the key's action and swallows the event; hands back anything else, and everything while text is edited.
    @MainActor static func handle(_ e: NSEvent, issue: IssueActions?, session: Session) -> NSEvent? {
        guard e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
            !(e.window?.firstResponder is NSTextView), let ch = e.charactersIgnoringModifiers?.first,
            let key = keys.first(where: { $0.0 == ch })?.1
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
    @FocusedValue(\.selectedLinks) private var links
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // The File menu's first section, in here for the focused issue Clone Issue… acts on.
        CommandGroup(replacing: .newItem) {
            Button("New Issue…") {
                // The list window knows which project it shows and fills it in; without one, a plain window.
                if NSApp.windows.contains(where: {
                    $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible
                }) {
                    session.createIssueRequested = true
                } else {
                    openWindow(id: "create", value: CreateRequest())
                }
            }
            .keyboardShortcut("n")
            .disabled(!session.isSignedIn)
            item("Clone Issue…", .clone, "n", [.command, .option])
            // New Issue windows closed with something in them, as Mail's Drafts; one picked reopens its window.
            let drafts = Drafts.shared.creates
            if drafts.isEmpty {
                Button("Drafts") {}.disabled(true)
            } else {
                Menu("Drafts") {
                    ForEach(drafts) { d in
                        Button(d.summary.isEmpty ? String(localized: "Untitled") : String(d.summary.prefix(60))) {
                            openWindow(id: "create", value: d.request)
                        }
                    }
                }
            }
            Button("Save Filter…") { list?.saveFilter?() }
                .keyboardShortcut("s")
                .disabled(list?.saveFilter == nil)
        }
        CommandMenu("Go") {
            Button("Assigned to Me") { go(.assigned) }.keyboardShortcut("1")
            Button("Reported by Me") { go(.reported) }.keyboardShortcut("2")
            // No Recently Viewed: issueHistory() is one account's, so All Accounts has no such list.
            Button("Watching") { go(.watching) }.keyboardShortcut("3")
            Divider()
            Button("Refresh") { session.reloadTick += 1 }.keyboardShortcut("r")
            Button("Refresh Projects") { Task { await session.refreshAll() } }
        }
        CommandGroup(before: .windowList) {
            // Mail's "Message Viewer" ⌘0: the list window, after it was closed behind an issue window.
            Button("Issues") { showMain() }.keyboardShortcut("0")
            // No Divider after it: a group placed before another shares one line with it.
            Button("Bin") { openWindow(id: "bin") }
            Divider()
        }
        // The toolbar items are here rather than ToolbarCommands': that group sat between the window-tab items and
        // this one, two lines on each side. First in the View menu now, this group's leading separator is the
        // menu's first item, which AppKit hides, and it shares one line with Show Sidebar below.
        CommandGroup(before: .sidebar) {
            Button("Open Board") { list?.openBoard?() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(list?.openBoard == nil)
            // Inline, as Mail's Sort By would be without its submenu. The section draws a separator on each side, so
            // a Divider beside it made a second line.
            Section("Sort By") {
                SortMenuItems(sort: list?.sort ?? .constant(ListFilters.Sort())).disabled(list?.sort == nil)
            }
        }
        CommandMenu("Issue") {
            item("Open in Browser", .openInBrowser, "o", [.command, .shift])
            // A window group keeps one window per issue, so from an issue's own window there is nothing to open.
            item("Open in New Window", .openInWindow, "o").disabled(issue?.embedded != true)
            Divider()
            // ⌘C with no text selected copies the key: see `keyItems`.
            Button((links?.count ?? 0) > 1 ? "Copy Links" : "Copy Link") {
                if let links {
                    copyToPasteboard(links.map(\.absoluteString).joined(separator: " "))
                } else {
                    issue?.perform(.copyLink)
                }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(links == nil && issue == nil)
            Divider()
            // AppKit keeps a submenu item enabled whatever .disabled says; with nothing to offer it is a plain item.
            if let transitions = issue?.transitions, !transitions.isEmpty {
                Menu("Change Status") {
                    ForEach(transitions) { t in Button(t.name) { issue?.perform(.transition(t.id)) } }
                }
            } else {
                Button("Change Status") {}.disabled(true)
            }
            item("Assign…", .assign, "a", [])
            item(issue?.assignedToMe == true ? "Unassign" : "Assign to Me", .assignToMe, "i", [])
            item(issue?.watching == true ? "Unwatch" : "Watch", .watch, "w", [])
            item("Remind Me…", .remind, "r", [.command, .option])
            Divider()
            item("Edit Summary", .editSummary, "e", []).disabled(issue?.canEditSummary != true)
            item("Edit Description", .editDescription, "e", [.command, .option]).disabled(
                issue?.canEditDescription != true)
            item("Add Comment", .comment, "m", [])
            item("Edit Labels…", .editLabels, "l", [])
            item("Attach Files…", .attach, "a", [.command, .option])
            item("Link Issue…", .link, "l", [.command, .shift])
            item("Log Work…", .logWork, "l", [.command, .option])
            item("Create Subtask…", .subtask, "n", [.command, .shift])
            Divider()
            item("Refresh Issue", .refresh, "r", [.command, .shift])
            item("Activity History", .history, "h", [.command, .option])
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
    @State private var forward = true
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let st = session.state(target.accountID) {
                IssueDetailView(
                    target: target,
                    open: {
                        trail.append(target)
                        navigating = true
                        forward = true
                        target = $0
                    },
                    back: trail.isEmpty
                        ? nil
                        : {
                            navigating = true
                            forward = false
                            target = trail.removeLast()
                        }, embedded: embedded, forward: forward
                )
                .equatable()
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
        .background(WindowCascader(target: target))
        // Opened (a link, Spotlight, Open in New Window) or shown again after a close: the main window's preview
        // lets the same issue go. Steps along this window's trail are not openings and leave the preview alone.
        .onAppear { if !embedded { session.announceWindow(target) } }
        .onChange(of: scenePhase) { old, new in
            if !embedded, old == .background, new != .background { session.announceWindow(target) }
        }
        // The main window's monitor covers the preview column; a window of its own needs one.
        .background(
            embedded
                ? nil
                : IssueKeyMonitor { e, issueActions in
                    if e.keyCode == 53, e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                        issueActions?.isEditing != true, NSApp.keyWindow === e.window, e.window?.showsPopover != true
                    {
                        // Escape in the comment box gives the keyboard up; editors with a Cancel keep theirs.
                        if let tv = e.window?.firstResponder as? NSTextView {
                            guard !tv.isFieldEditor else { return e }
                            e.window?.focusList()
                            return nil
                        }
                        // Otherwise it steps back along the trail, as in the preview. At its start it does nothing:
                        // a window is closed with ⌘W.
                        if let back = issueActions?.back {
                            back()
                            return nil
                        }
                    }
                    return Shortcuts.handle(e, issue: issueActions, session: session)
                }
        )
    }
}

/// A window's key monitor that reads the key window's issue actions itself. Held by the window, the focused value
/// re-rendered all of it (the main window: sidebar and list too) whenever the page it comes from changed.
struct IssueKeyMonitor: View {
    let handler: (NSEvent, IssueActions?) -> NSEvent?
    @FocusedValue(\.issueActions) private var issue

    var body: some View { WindowEventMonitor(mask: .keyDown) { handler($0, issue) } }
}

func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}

/// What ⌘C copies from issues with no text selected (`onCopyCommand`): their keys, space-separated.
func keyItems(_ keys: [String]) -> [NSItemProvider] {
    keys.isEmpty ? [] : [NSItemProvider(object: keys.joined(separator: " ") as NSString)]
}

/// Offsets a new issue window from the one opened before it, as document windows do. SwiftUI puts every
/// window of a group at the same spot. A window the system restored keeps its own frame.
private struct WindowCascader: NSViewRepresentable {
    /// The issue the window shows, for `IssueWindows`: this view knows the window and the issue both.
    let target: IssueTarget
    func makeNSView(context: Context) -> Cascader { Cascader() }
    func updateNSView(_ view: Cascader, context: Context) { view.target = target }

    final class Cascader: NSView {
        private var done = false
        var target: IssueTarget? { didSet { if target != oldValue { register() } } }
        /// An issue window of its own, not the main window's preview column.
        private func register() {
            guard let window, let target, window.identifier?.rawValue.hasPrefix("issue") == true else { return }
            IssueWindows.show(target, in: window)
        }
        override func viewDidMoveToWindow() {
            register()
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

/// Every issue window by the issue it shows, so a request raises the window there is rather than opening a second:
/// a link that launched the app found the restored window up but not yet known to SwiftUI by its value, and its
/// title not set yet (CON-249). A second window for an issue that has one closes itself, the first coming forward.
@MainActor enum IssueWindows {
    private struct Weak { weak var window: NSWindow? }
    private static var shown: [IssueTarget: Weak] = [:]

    static func window(for target: IssueTarget) -> NSWindow? {
        shown[target]?.window.flatMap { $0.isVisible ? $0 : nil }
    }

    /// `window` shows `target` now (a step along its trail moves it to another issue).
    static func show(_ target: IssueTarget, in window: NSWindow) {
        shown = shown.filter { $0.value.window != nil && $0.value.window !== window }
        if let other = self.window(for: target), other !== window {
            DispatchQueue.main.async {
                other.makeKeyAndOrderFront(nil)
                window.close()
            }
            return
        }
        shown[target] = Weak(window: window)
    }
}
