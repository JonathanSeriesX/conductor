import SwiftUI

/// What the issue page in the key window can do. The Issue menu reads it, so every action and its
/// shortcut is discoverable in the menu bar and works from any issue window.
struct IssueActions {
    enum Action: Hashable {
        case openInBrowser, openInWindow, copyLink, copyKey, copyMarkdown
        case assign, assignToMe, watch, remind, transition(String)
        case editSummary, editDescription, comment, attach, link, logWork, subtask, refresh
    }
    let key: String
    let watching: Bool
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

    private func item(_ title: LocalizedStringKey, _ action: IssueActions.Action, _ key: KeyEquivalent? = nil, _ modifiers: EventModifiers = .command) -> some View {
        Button(title) { issue?.perform(action) }
            .keyboardShortcut(key.map { KeyboardShortcut($0, modifiers: modifiers) })
            .disabled(issue == nil)
    }
}

/// An issue in a window of its own, so two can sit side by side. Links inside it navigate in place.
struct IssueWindow: View {
    @State var target: IssueTarget
    /// Issues this window showed before the current one, so a jump to a subtask or link can come back.
    @State private var trail: [IssueTarget] = []
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let st = session.state(target.accountID) {
                IssueDetailView(target: target, open: { trail.append(target); target = $0 },
                                back: trail.isEmpty ? nil : { target = trail.removeLast() })
                    .environment(\.jira, st)
                    .id(target)
            } else if session.isRestoring {
                ZStack { Backdrop(); ProgressView() }
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
            }
        }
        .writingToolsBehavior(.disabled)
        .background(WindowCascader())
        .frame(minWidth: 640, minHeight: 480)
        .onChange(of: target, initial: true) { session.recordView(target) }
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
            let others = NSApp.windows.filter { $0 !== window && $0.isVisible && $0.identifier?.rawValue.hasPrefix("issue") == true }
            guard let last = others.max(by: { $0.orderedIndex > $1.orderedIndex }) else { return }
            if abs(last.frame.origin.x - window.frame.origin.x) < 2, abs(last.frame.maxY - window.frame.maxY) < 2 {
                window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
            }
        }
    }
}
