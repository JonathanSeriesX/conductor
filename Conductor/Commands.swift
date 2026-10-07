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
        CommandMenu("Go") {
            Button("Assigned to Me") { session.navigationRequest = session.filters(for: .assigned) }.keyboardShortcut("1")
            Button("Reported by Me") { session.navigationRequest = session.filters(for: .reported) }.keyboardShortcut("2")
            Button("Recently Viewed") { session.navigationRequest = session.filters(for: .recent) }.keyboardShortcut("3")
            Button("Watching") { session.navigationRequest = session.filters(for: .watching) }.keyboardShortcut("4")
            Button("Starred") { session.navigationRequest = session.filters(for: .starred) }.keyboardShortcut("5")
            Divider()
            Button("Reload") { session.reloadTick += 1 }.keyboardShortcut("r")
            Button("Refresh Projects") { Task { await session.refreshAll() } }
        }
        CommandGroup(after: .newItem) {
            Button("Save Filter…") { list?.saveFilter?() }
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let st = session.state(target.accountID) {
                IssueDetailView(target: target, open: { target = $0 })
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
        .frame(minWidth: 640, minHeight: 480)
        .onChange(of: target, initial: true) { session.recordView(target) }
    }
}

func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}
