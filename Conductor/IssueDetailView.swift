import Quartz
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class IssueDetailStore {
    var issue: Issue?
    var transitions: [Transition] = []
    var editMeta: EditMeta?
    var sprints: [Sprint] = []
    var linkTypes: [LinkType] = []
    var children: [Issue] = []
    var error: String?
    var isWorking = false
    var previewURL: URL?
    /// Jira answered 404: the issue was deleted or moved since it was cached.
    var gone = false

    var priorities: [Priority] {
        editMeta?.fields["priority"]?.allowedValues?.compactMap { v in
            guard let o = v.object, let id = o["id"]?.string, let name = o["name"]?.string else { return nil }
            return Priority(id: id, name: name, iconUrl: o["iconUrl"]?.string.flatMap(URL.init))
        } ?? []
    }

    func canEdit(_ field: String?) -> Bool { field.flatMap { editMeta?.fields[$0] } != nil }

    /// Types this issue can change to, from its edit screen. Empty when the type is not editable.
    var issueTypes: [IssueType] {
        editMeta?.fields["issuetype"]?.allowedValues?.compactMap { v in
            guard let o = v.object, let id = o["id"]?.string, let name = o["name"]?.string else { return nil }
            return IssueType(
                id: id, name: name, iconUrl: o["iconUrl"]?.string.flatMap(URL.init), subtask: o["subtask"]?.bool)
        } ?? []
    }

    /// Every label on the site, fetched once per page for the labels editor.
    var allLabels: [String] = []
    /// Full records of the subtasks, children, parent and linked issues, for what their refs lack (the assignee).
    var related: [String: Issue] = [:]

    /// Values editmeta offers for components or fix versions; archived versions are left out.
    func options(_ field: String) -> [NamedRef] {
        editMeta?.fields[field]?.allowedValues?.compactMap { v in
            guard let o = v.object, o["archived"] != .bool(true), let id = o["id"]?.string, let name = o["name"]?.string
            else { return nil }
            return NamedRef(id: id, name: name)
        } ?? []
    }

    /// The story points field on this issue's edit screen, out of the site's candidates.
    func pointsField(_ client: JiraClient?) -> String? { client?.pointsFields.first { editMeta?.fields[$0] != nil } }

    /// A row from a list has the summary and status but no description or comments yet.
    var isPartial: Bool { issue?.fields.comment == nil }

    /// The issue this store holds. One store serves the preview column across selections.
    private(set) var key: String?

    func load(_ state: AccountState, key: String, full: Bool = true) async {
        let client = state.client
        var pending: Task<Issue, Error>?
        if self.key != key {
            // Another issue. Everything the page is built from is gathered first and put in place in one step;
            // until then the previous issue stays on screen. Shown piecemeal (the list row's copy, then the
            // disk's), each step pushed the cards around. Replies for an issue left meanwhile are dropped by the
            // key checks after each await.
            self.key = key
            let account = state.account
            async let diskIssue: Issue? = DiskCache.loadAsync(account: account, name: "issue-\(key)")
            async let diskMeta: EditMeta? = DiskCache.loadAsync(account: account, name: "editmeta-\(key)")
            async let diskTransitions: [Transition]? = DiskCache.loadAsync(account: account, name: "transitions-\(key)")
            async let diskChildren: [Issue]? =
                full ? DiskCache.loadAsync(account: account, name: "children-\(key)") : nil
            let (cached, meta, trans, kids) = await (diskIssue, diskMeta, diskTransitions, diskChildren)
            guard self.key == key else { return }
            // Memory's copy when it is full, no less complete than the disk's and at least as new.
            var next = cached
            if let p = state.peek[key], p.fields.comment != nil, p.isComplete || cached?.isComplete != true,
                (p.fields.updated ?? .distantPast) >= (cached?.fields.updated ?? .distantPast)
            {
                next = p
            }
            if next == nil {
                // Never opened on this Mac: wait for the whole issue rather than show the row's copy and grow it
                // a moment later. Right once beats fast and shifting; past a second and a half, the row's copy.
                let fetch = Task { try await client.issue(key) }
                pending = fetch
                next = await Self.first(of: fetch, within: .milliseconds(1500))
                guard self.key == key else { return }
            } else if let n = next, !n.isComplete {
                // A prefetched copy carries Jira's first 20 comments: the rest first, so the thread shows whole
                // rather than growing under the reader. Offline or slow, the copy as it is after three seconds.
                let complete = Task { try await client.completing(n) }
                next = await Self.first(of: complete, within: .seconds(3)) ?? n
                guard self.key == key else { return }
            }
            let shown = next ?? state.peek[key]
            // Assignees of subtasks, children and links from memory and disk, before any request.
            let seeds = await Self.known(Self.relatedKeys(of: shown, children: kids ?? []), state: state)
            guard self.key == key else { return }
            var list: [Sprint] = []
            if full, let project = shown?.fields.project?.key,
                meta.map({ m in client.sprintField.map { m.fields[$0] != nil } ?? false }) ?? false
            {
                list = await state.cachedSprints(project: project)  // never Jira: the fresh list comes after
                guard self.key == key else { return }
            }
            issue = shown
            editMeta = meta ?? shown.flatMap { state.editMetaByWorkflow[AccountState.workflowKey($0)] }
            transitions = trans ?? shown.flatMap { state.transitionsByWorkflow[AccountState.workflowKey($0)] } ?? []
            children = kids ?? []
            sprints = list
            error = nil
            gone = false
            allLabels = []
            related = seeds
        }
        do {
            let i = pending ?? Task { try await client.issue(key) }
            async let t = client.transitions(key)
            async let m = client.editMeta(key)
            async let kids = full ? client.search(jql: client.childrenJQL([key]) + " ORDER BY created ASC") : nil
            async let types = full ? state.linkTypes() : nil
            let fresh = try await i.value
            guard self.key == key else { return }
            update(\.issue, fresh)
            DiskCache.saveAsync(fresh, account: state.account, name: "issue-\(key)")
            Spotlight.index([fresh], host: state.host)
            if let fresh = try? await t, self.key == key {
                update(\.transitions, fresh)
                DiskCache.saveAsync(fresh, account: state.account, name: "transitions-\(key)")
                if let i = issue { state.learnTransitions(fresh, of: i) }
            }
            if let fresh = try? await m, self.key == key {
                update(\.editMeta, fresh)
                DiskCache.saveAsync(fresh, account: state.account, name: "editmeta-\(key)")
            }
            if full {
                if let page = try? await kids, self.key == key {
                    update(\.children, page.issues.filter { !$0.fields.issuetype.isSubtask })
                    DiskCache.saveAsync(children, account: state.account, name: "children-\(key)")
                }
                if let list = await types { update(\.linkTypes, list) }
                prefetchRelated(state)
            }
        } catch {
            guard self.key == key else { return }
            if (error as? JiraError)?.status == 404 {
                gone = true
                issue = nil
                return
            }
            if !error.isOffline, !error.isCancelled { self.error = error.localizedDescription }
            return
        }
        if full, canEdit(client.sprintField), let project = issue?.fields.project?.key {
            let list = await state.sprints(project: project)
            if self.key == key { update(\.sprints, list) }
        }
        if full, let project = issue?.fields.project?.key {
            state.warm("assignable-\(project)") { try await client.assignableUsers(project: project, query: "") }
        }
        if full, allLabels.isEmpty, canEdit("labels") {
            let (now, fresh) = state.memo("labels") { try await client.labels() }
            if let now, self.key == key { update(\.allLabels, now) }
            if let list = await fresh.value, self.key == key { update(\.allLabels, list) }
        }
    }

    /// Takes a change announced from elsewhere (a card moved on a board) before this page's own reload.
    func apply(_ c: Session.IssueChange) {
        guard c.targets.contains(where: { $0.key == key }) else { return }
        if let i = c.issue {
            if i.key == key { update(\.issue, i) }
        } else if let change = c.change, var i = issue {
            change(&i)
            update(\.issue, i)
        }
    }

    /// The task's value if it lands within `limit`, else nil (the task keeps running).
    private static func first<T: Sendable>(of task: Task<T, Error>, within limit: Duration) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { try? await task.value }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Assigns only a real change: every write re-renders the page, and Jira's answer is usually what the disk had.
    private func update<T: Equatable>(_ path: ReferenceWritableKeyPath<IssueDetailStore, T>, _ value: T) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }

    /// Full records for everything this page can open with a click: subtasks, children, the parent and linked
    /// issues. One batched request, skipping what is already on disk.
    private func prefetchRelated(_ state: AccountState) {
        let keys = Self.relatedKeys(of: issue, children: children)
        for k in keys where related[k] == nil { if let p = state.peek[k] { related[k] = p } }
        let missing = Set(keys).filter { state.prefetched[$0] == nil || state.peek[$0] == nil }
        guard !missing.isEmpty else { return }
        let key = self.key
        Task { @MainActor in
            for i in await state.fetchDetails(Array(missing)) where self.key == key { related[i.key] = i }
        }
    }

    /// The keys this page can open with a click.
    private static func relatedKeys(of issue: Issue?, children: [Issue]) -> [String] {
        guard let issue else { return [] }
        var keys =
            (issue.fields.subtasks ?? []).map(\.key) + children.map(\.key)
            + (issue.fields.issuelinks ?? []).compactMap { $0.other?.key }
        if let p = issue.fields.parent?.key { keys.append(p) }
        return keys
    }

    /// What memory knows about `keys`, then each issue's own file (a Done subtask is in no open list but was
    /// prefetched once). The files are read and decoded off the main thread: a page with fifteen children held
    /// the main thread for every one of them on a step.
    private static func known(_ keys: [String], state: AccountState) async -> [String: Issue] {
        var found: [String: Issue] = [:]
        for k in keys { found[k] = state.peek[k] }
        let missing = keys.filter { found[$0] == nil }
        guard !missing.isEmpty else { return found }
        let account = state.account
        let disk = await Task.detached(priority: .userInitiated) {
            missing.compactMap { DiskCache.load(Issue.self, account: account, name: "issue-\($0)") }
        }.value
        for i in disk { found[i.key] = i }
        return found
    }

    /// Runs a write, then refreshes only what a write can change: the issue, its transitions and editmeta.
    /// False when the write failed, so the caller can keep the user's draft.
    @discardableResult
    func perform(_ state: AccountState, key: String, _ op: @Sendable (JiraClient) async throws -> Void) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        do { try await op(state.client) } catch {
            if !error.isCancelled { self.error = error.localizedDescription }
            return false
        }
        // The page may show another issue by now: refreshing this one would put its body under that key.
        if self.key == key { await load(state, key: key, full: false) }
        return true
    }
}

struct IssueDetailView: View {
    let target: IssueTarget
    var open: (IssueTarget) -> Void
    /// Set by the window when there is an issue to go back to.
    var back: (() -> Void)? = nil
    /// In the main window's preview column rather than a window of its own.
    var embedded = false
    /// False while the window goes back along its trail: the title then slides the other way.
    var forward = true
    @Environment(Session.self) private var session
    @Environment(\.jira) private var jira
    @Environment(\.openWindow) private var openWindow
    @State private var store = IssueDetailStore()
    private var key: String { target.key }
    /// Keys from subtasks, links and parents live in the same account as this issue.
    private func open(_ key: String) {
        let t = IssueTarget(accountID: target.accountID, key: key)
        // ⌘-click opens beside, as links do in a browser.
        if NSEvent.modifierFlags.contains(.command) { openWindow(id: "issue", value: t) } else { open(t) }
    }
    private func openWindow(_ key: String) {
        openWindow(id: "issue", value: IssueTarget(accountID: target.accountID, key: key))
    }

    // Editing state
    @State private var summaryDraft: String?
    @State private var descriptionDraft: String?
    @State private var descriptionMentions: [String: String] = [:]
    /// What the editors opened with, so an untouched draft is never written back (the Markdown trip loses panels and media).
    @State private var descriptionOriginal = ""
    /// Where the click that started an edit landed, so the caret goes there and not to the end.
    @State private var editClick: NSPoint?
    /// The summary editor just opened and its caret still has to be placed.
    @State private var caretPending = false
    /// The same for the description, handed to its composer, which owns that editor's selection.
    /// When a link in the description was last clicked, so that click does not also start editing.
    @State private var editOriginal = ""
    /// The comment whose editor is open. An id, not the comment: the draft outlives the page's copy of the issue.
    @State private var editingCommentID: String?
    @State private var editDraft = ""
    @State private var editMentions: [String: String] = [:]
    @State private var showAssign = false
    @State private var showLabels = false
    /// Too near the bottom of the window for the labels editor to open below its row.
    @State private var labelsLow = false
    /// Scrolls what a key acts on into view first: see `PageReveal`.
    @State private var pageReveal = PageReveal()
    @State private var showLink = false
    @State private var showLogWork = false
    @State private var showDueDate = false
    @State private var showRemind = false
    @State private var showParent = false
    @State private var showWatchers = false
    @State private var showStatus = false
    @State private var showPriority = false
    @State private var isDropTargeted = false
    @FocusState private var summaryFocused: Bool
    @FocusState private var descriptionFocused: Bool
    @FocusState private var commentFocused: Bool
    @State private var commentRequest = 0
    /// Content is under the toolbar: the preview column then draws the toolbar's band.
    @State private var scrolled = false
    /// The issue on screen: the previous one stays until the next has loaded, and its folds go with it.
    private var shownKey: String { store.issue?.key ?? key }
    /// Folded cards and work-log groups, per issue, as this Mac remembers them.
    @State private var folded = Folds.load()

    private func fold(_ id: String) -> Binding<Bool> {
        Binding(
            get: { folded.contains(id) },
            set: { on in
                withAnimation(.smooth(duration: 0.25)) { if on { folded.insert(id) } else { folded.remove(id) } }
                Folds.save(folded)
            })
    }
    /// The thread's order, the same on every issue.
    @AppStorage("commentsNewestFirst") private var newestFirst = true
    /// Refresh Issue is loading: the Refresh button spins meanwhile.
    @State private var refreshing = false
    /// The load this page's own write would trigger: `perform` has refreshed the issue already.
    @State private var ownLoad = ""
    @Environment(\.scenePhase) private var scenePhase
    private var loadID: String { "\(key)|\(session.reloadTick)|\(session.writeTicks[key] ?? 0)" }

    var body: some View {
        Group {
            if let issue = store.issue {
                content(issue)
            } else if store.gone {
                ContentUnavailableView(
                    "\(key) no longer exists", systemImage: "trash",
                    description: Text("It was deleted or moved in Jira."))
            } else if store.error == nil {
                DelayedSpinner(size: .regular)
            } else {
                ContentUnavailableView("Couldn't load \(key)", systemImage: "exclamationmark.triangle")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Backdrop())
        .navigationTitle(key)  // the Window menu and restoration; the toolbar draws its own
        .toolbar(removing: .title)
        // Not customizable: in the preview column this toolbar comes and goes with the selection, and SwiftUI
        // crashed applying saved customizations while it swapped with the empty column's in one pass.
        .toolbar { toolbar }
        .focusedSceneValue(\.issueActions, actions)
        // SwiftUI keeps a closed issue window with its state and shows that same one for the next open of the issue,
        // with no appear or task; its scene comes back from .background, and the page refreshes itself as Refresh
        // Issue does. (An AppKit observer on the window for this kept about 8 MB per closed window alive.)
        .onChange(of: scenePhase) { old, new in
            if old == .background, new != .background, store.issue != nil, let jira {
                Task { await store.load(jira, key: key) }
            }
        }
        .onChange(of: session.lastChange?.count) {
            if let c = session.lastChange, c.targets.contains(target) { store.apply(c) }
        }
        // A write to this issue in another window bumps its tick, so this page follows it.
        .task(id: loadID) {
            if let jira, store.key != key || loadID != ownLoad { await store.load(jira, key: key) }
        }
        // The same view serves one issue after another (a fresh view would take the toolbar with it for a frame).
        .onChange(of: target) { old, _ in
            commitSummary(of: old)
            summaryDraft = nil
            caretPending = false
            for show in [
                $showAssign, $showLabels, $showLink, $showLogWork, $showDueDate, $showRemind, $showParent,
                $showWatchers, $showStatus, $showPriority,
            ] { show.wrappedValue = false }
            unstash()
        }
        // The open editors and their text are the issue's, kept on disk: back from another issue, or after a
        // relaunch, they are as they were. Every change goes straight to the store; the switch only reads it.
        .onAppear(perform: unstash)
        .onChange(of: descriptionDraft) { stash() }
        .onChange(of: editDraft) { stash() }
        .onChange(of: editingCommentID) { stash() }
        .errorAlert($store.error)
        .quickLookPreview($store.previewURL)
        .dropDestination(for: URL.self) { urls, _ in
            upload(urls: urls)
            return true
        } isTargeted: {
            isDropTargeted = $0
        }
        .overlay {
            if isDropTargeted {
                ContentUnavailableView("Drop to attach", systemImage: "paperclip")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.ultraThinMaterial)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        .onPasteCommand(of: [.fileURL, .png, .tiff, .image]) { _ in pasteAttachment() }
        // onPasteCommand needs the focus; this takes ⌘V with files or an image while no text view has it.
        .background(
            WindowEventMonitor(mask: .keyDown) { e in
                guard e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                    e.charactersIgnoringModifiers == "v", !(e.window?.firstResponder is NSTextView),
                    store.issue != nil,
                    NSPasteboard.general.canReadObject(
                        forClasses: [NSURL.self, NSImage.self], options: [.urlReadingFileURLsOnly: true])
                else { return e }
                pasteAttachment()
                return nil
            }
        )
    }

    /// "• M to add": the key the current scheme binds to `action`, worded by `phrase`, for a caption; nil when none.
    private func hint(_ action: IssueActions.Action, _ phrase: (String) -> String) -> String? {
        Shortcuts.hint(for: action).map { "• " + phrase($0) }
    }

    private func stash() {
        Drafts.shared.update(target) {
            $0.description = descriptionDraft
            $0.descriptionMentions = descriptionMentions
            $0.descriptionOriginal = descriptionOriginal
            $0.editingComment = editingCommentID
            $0.edit = editDraft
            $0.editMentions = editMentions
            $0.editOriginal = editOriginal
        }
    }

    private func unstash() {
        let d = Drafts.shared[target]
        descriptionDraft = d.description
        descriptionMentions = d.descriptionMentions
        descriptionOriginal = d.descriptionOriginal
        editingCommentID = d.editingComment
        editDraft = d.edit
        editMentions = d.editMentions
        editOriginal = d.editOriginal
    }

    // MARK: Layout

    private func content(_ issue: Issue) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(issue)
                    GlassGroup(spacing: 16) {
                        if embedded {
                            // The preview column is narrow: the fields go under the body, the first four above the comments.
                            cards(issue)
                            metadata {
                                statusField(issue)
                                assigneeField(issue)
                                priorityField(issue)
                                reporterField(issue)
                            }
                            .pageTarget(PageTarget.fields, in: pageReveal)
                            commentsCard(issue)
                            metadata { fields(issue) }
                        } else {
                            HStack(alignment: .top, spacing: 16) {
                                VStack(alignment: .leading, spacing: 16) {
                                    cards(issue)
                                    commentsCard(issue)
                                }
                                GlassCard {
                                    VStack(alignment: .leading, spacing: 14) {
                                        statusField(issue)
                                        priorityField(issue)
                                        assigneeField(issue)
                                        reporterField(issue)
                                        fields(issue)
                                    }
                                    .font(.callout)
                                }
                                .frame(width: 250)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
                .padding(.top, embedded ? 10 : 17)  // the crumb sits on the line of the list's chips
                .coordinateSpace(.named(PageReveal.space))
                .background(PageKeys(standalone: !embedded, reveal: pageReveal))
                // The anchor is the padded page, not the header: scrolled to its top, the header kept none of the
                // padding above it, and every next issue sat 10 pt higher than the first.
                .id("top")
            }
            // The toolbar has no background, so blur what scrolls under it instead of letting buttons sit on text.
            .softScrollEdge(band: embedded ? scrolled : nil)
            .modifier(ScrolledWatch(on: embedded, scrolled: $scrolled))
            // When the next issue is on screen, not when it was asked for: the previous one stays until then.
            .onChange(of: store.issue?.key) { proxy.scrollTo("top", anchor: .top) }
            #if DEBUG
                .task {
                    guard ProcessInfo.processInfo.environment["CONDUCTOR_SCROLL"] == "comments" else { return }
                    try? await Task.sleep(for: .seconds(1))
                    proxy.scrollTo("comments", anchor: .top)
                }
            #endif
        }
        .environment(\.adfAttachments, issue.fields.attachment ?? [])
        .environment(\.previewURL, $store.previewURL)
    }

    /// Everything between the description and the comments.
    @ViewBuilder private func cards(_ issue: Issue) -> some View {
        descriptionCard(issue).pageTarget(PageTarget.description, in: pageReveal)
        if let atts = issue.fields.attachment, !atts.isEmpty {
            GlassCard(title: "Attachments", hint: hint(.attach) { String(localized: "\($0) to add") }) {
                attachments(atts)
            }
        }
        if let subs = issue.fields.subtasks, !subs.isEmpty {
            GlassCard(
                title: "Subtasks", detail: "• " + String(localized: "\(subs.count) tasks"),
                hint: hint(.subtask) { String(localized: "\($0) to add") },
                collapsed: fold("\(shownKey)|subtasks")
            ) { refs(subs) }
        }
        if !store.children.isEmpty {
            GlassCard(
                title: "Child Issues", detail: "• " + String(localized: "\(store.children.count) issues"),
                collapsed: fold("\(shownKey)|children")
            ) {
                children(store.children)
            }
        }
        if let links = issue.fields.issuelinks, !links.isEmpty {
            GlassCard(
                title: "Linked Issues", detail: "• " + String(localized: "\(links.count) issues"),
                hint: hint(.link) { String(localized: "\($0) to add") },
                collapsed: fold("\(shownKey)|links")
            ) { linksList(links) }
        }
        // Always there and never folded: who spent how long matters, and it is rarely more than a few lines, as
        // each person's entries are folded under their total.
        let logs = issue.fields.worklog?.worklogs ?? []
        GlassCard(
            title: "Work Log", detail: worklogTotals(issue, logs),
            hint: hint(.logWork) { String(localized: "\($0) to log") }
        ) {
            if store.isPartial {
                DelayedSpinner()
            } else if logs.isEmpty {
                Text("No work logged").foregroundStyle(.tertiary)
            } else {
                worklogs(logs)
            }
        }
    }

    private func header(_ issue: Issue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if embedded { Crumb(issue: store.issue, key: key, open: open) }  // a window carries it in its toolbar
            if summaryDraft != nil {
                // The field takes the title's place exactly: the padding inside the background equals the negative
                // padding outside it, so the text does not move and the page below stays put.
                TextField("Summary", text: Binding($summaryDraft, or: ""), axis: .vertical)
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .textFieldStyle(.plain)
                    .lineLimit(1...)
                    .focused($summaryFocused)
                    // Leaving the field for anything else on the page saves it, as a blurred field does on the web:
                    // left open without the keyboard, it sat there frozen. A popover opening reports the field
                    // unfocused while it still has the keyboard, so the save waits a turn and looks again; an app
                    // switch keeps the focus and saves nothing.
                    .onChange(of: summaryFocused) { _, focused in
                        guard !focused else { return }
                        let shown = store.issue?.key
                        DispatchQueue.main.async {
                            let fr = NSApp.keyWindow?.firstResponder as? NSTextView
                            let stillHere = fr?.isFieldEditor == true && !(fr?.delegate is NSSearchField)
                            guard summaryDraft != nil, !summaryFocused, !stillHere, store.issue?.key == shown,
                                NSApp.isActive
                            else { return }
                            saveSummary(blurred: true)
                        }
                    }
                    .onSubmit { saveSummary() }
                    .onExitCommand {
                        summaryDraft = nil
                        NSApp.keyWindow?.focusList()
                    }
                    // Unfocused, the field leaves out its last line when SwiftUI rounds its height a fraction of a
                    // point under the text's, so it blinked as the editor opened and was gone
                    // whenever the editor lost the keyboard. Until it has the keyboard the title is drawn as text in
                    // its place; clicks go through to the field.
                    .opacity(summaryFocused ? 1 : 0)
                    .overlay(alignment: .topLeading) {
                        if !summaryFocused {
                            Text(summaryDraft ?? "")
                                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                                .fixedSize(horizontal: false, vertical: true)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
                    .padding(.horizontal, -8).padding(.vertical, -4)
                    .help("↩ to save · esc to cancel")
                    .focusSoon($summaryFocused)
                    .onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) {
                        placeCaret(in: $0.object as? NSTextView)
                        alignSummaryEditor($0.object as? NSTextView)
                    }
            } else {
                // A click edits, as on the web; a right-click is the issue's menu. Not selectable text, whose
                // menu (Cut, Paste, Font…) treated the title as a writing field.
                Text(issue.fields.summary)
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .contentShape(.rect)
                    .onTapGesture {
                        guard store.canEdit("summary") else { return }
                        editClick = NSEvent.mouseLocation
                        caretPending = true
                        summaryDraft = issue.fields.summary
                    }
                    .contextMenu {
                        if let jira { IssueMenu(issues: [issue], state: jira) { op in run { _ in try await op() } } }
                    }
            }
        }
        .pageTarget(PageTarget.summary, in: pageReveal)
    }

    private func descriptionCard(_ issue: Issue) -> some View {
        GlassCard(title: "Description", hint: hint(.editDescription) { String(localized: "\($0) to edit") }) {
            if descriptionDraft != nil {
                Composer(
                    text: Binding($descriptionDraft, or: ""), mentions: $descriptionMentions,
                    placeholder: "Description", minHeight: 140, maxHeight: 420, uploadImage: uploadPasted,
                    focus: $descriptionFocused,
                    actions: AnyView(
                        HStack(spacing: 10) {
                            Button("Cancel") { cancelDescriptionEdit() }.glassButton().keyboardShortcut(.cancelAction)
                            // ⌘↩ belongs to whichever editor has focus; the comment box has the same shortcut.
                            Button("Save") { saveDescription() }.glassButton(prominent: true)
                                .keyboardShortcut(
                                    descriptionFocused ? KeyboardShortcut(.return, modifiers: .command) : nil)
                        })
                )
                .focusSoon($descriptionFocused)
                if issue.fields.description?.hasLossyNodes == true, let web = jira?.client.browseURL(key) {
                    Label {
                        Text(
                            "This description has images, panels or other content the editor can't keep. Saving replaces them with the text shown here; Cancel leaves the description as it is."
                        ) + Text(verbatim: " ") + Text(editOnWeb(web))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.caption).foregroundStyle(.orange)
                    // The link closes this editor as it opens the web's: that one keeps what this one would lose.
                    .environment(
                        \.openURL,
                        OpenURLAction { url in
                            cancelDescriptionEdit()
                            return .systemAction(url)
                        })
                }
            } else if let d = issue.fields.description, !(d.content ?? []).isEmpty {
                let flip: ((String) -> Void)? = store.canEdit("description") ? { toggleTask($0) } : nil
                DescriptionText(
                    node: d, attachments: issue.fields.attachment ?? [], loadImage: loadImage, onPreview: preview,
                    client: jira?.client, toggleTask: flip
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if store.isPartial {
                DelayedSpinner()
            } else if store.canEdit("description") {
                Text("Add a description…").foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                    .onTapGesture { beginDescriptionEdit(issue) }
            } else {
                Text("No description").foregroundStyle(.tertiary)
            }
            // Labels close the description, as tags close a post. A click edits them.
            let labels = issue.fields.labels ?? []
            if !labels.isEmpty || store.canEdit("labels") {
                Button {
                    showLabels = true
                } label: {
                    if labels.isEmpty {
                        Label(
                            Shortcuts.hint(for: .editLabels).map { String(localized: "\($0) to add labels…") }
                                ?? String(localized: "Add labels…"), systemImage: "tag"
                        )
                        .foregroundStyle(.tertiary)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "tag").foregroundStyle(.tertiary)
                            Wrap {
                                ForEach(labels, id: \.self) { Chip(text: $0) }
                                if let h = hint(.editLabels, { String(localized: "\($0) to edit labels") }) {
                                    Text(h).keyHint(.caption).padding(.vertical, 3)  // the chip's, so the lines of text meet
                                }
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!store.canEdit("labels"))
                .pageTarget(PageTarget.labels, in: pageReveal)
                // Above the row when the whole editor (field, six matches, Save) would run past the bottom of the
                // window: opened below, it jumps up as the matches appear.
                .onGeometryChange(for: Bool.self) { p in
                    (p.bounds(of: .scrollView)?.maxY ?? .infinity) - p.size.height < 360
                } action: {
                    labelsLow = $0
                }
                .popover(isPresented: $showLabels, arrowEdge: labelsLow ? .top : .bottom) {
                    LabelsEditor(labels: labels, suggestions: store.allLabels) { new in
                        showLabels = false
                        run { try await $0.editIssue(key, fields: ["labels": .array(new.map(JSONValue.string))]) }
                    }
                }
            }
        }
        // The History tab, in a window of its own; grey and small, as the bin icons are. A window has it in its
        // toolbar instead.
        .overlay(alignment: .topTrailing) {
            if embedded {
                Button {
                    perform(.history)
                } label: {
                    Label("Activity History", systemImage: "clock.arrow.circlepath").labelStyle(.iconOnly)
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary).help("Activity history (⌥⌘H)").padding(18)
            }
        }
    }

    /// Two columns whatever the width: one would leave half the card empty, three would squeeze the values.
    private func metadata<V: View>(@ViewBuilder _ fields: () -> V) -> some View {
        GlassCard {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: 2),
                alignment: .leading, spacing: 14
            ) { fields() }
            .font(.callout)
        }
    }

    /// The four values a reader wants first, above the comments.
    @ViewBuilder private func statusField(_ issue: Issue) -> some View {
        field("Status", hint: hint(.changeStatus) { String(localized: "\($0) to change") }) {
            Menu {
                ForEach(store.transitions) { t in
                    Toggle(
                        isOn: Binding(
                            get: { t.to.id == issue.fields.status.id },
                            set: { on in if on { transition(t.id) } })
                    ) { Text(t.name) }
                }
            } label: {
                StatusPill(status: issue.fields.status)
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
            .disabled(store.transitions.isEmpty)
            .editable(!store.transitions.isEmpty)
            .pageTarget(PageTarget.status, in: pageReveal)
            // The keyboard's way in (Linear's S): a menu cannot be opened from code, a popover can.
            .popover(isPresented: $showStatus, arrowEdge: embedded ? .bottom : .leading) {
                PickList(items: store.transitions.map { ($0.id, $0.name, $0.to.id == issue.fields.status.id) }) { id in
                    showStatus = false
                    transition(id)
                }
            }
        }
    }

    @ViewBuilder private func priorityField(_ issue: Issue) -> some View {
        field("Priority", hint: hint(.changePriority) { String(localized: "\($0) to change") }) {
            if store.canEdit("priority"), !store.priorities.isEmpty {
                Menu {
                    ForEach(store.priorities, id: \.id) { p in
                        Button(p.name) {
                            run { try await $0.editIssue(key, fields: ["priority": .object(["id": .string(p.id)])]) }
                        }
                    }
                } label: {
                    priorityLabel(issue.fields.priority)
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                .editable()
                .pageTarget(PageTarget.priority, in: pageReveal)
                .popover(isPresented: $showPriority, arrowEdge: embedded ? .bottom : .leading) {
                    PickList(items: store.priorities.map { ($0.id, $0.name, $0.id == issue.fields.priority?.id) }) {
                        id in
                        showPriority = false
                        run { try await $0.editIssue(key, fields: ["priority": .object(["id": .string(id)])]) }
                    }
                }
            } else {
                priorityLabel(issue.fields.priority)
            }
        }
    }

    @ViewBuilder private func assigneeField(_ issue: Issue) -> some View {
        // "I to set myself" only while the issue is someone else's.
        let mine = issue.fields.assignee != nil && issue.fields.assignee?.accountId == jira?.me?.accountId
        field(
            "Assignee",
            hint: hint(.assign) { a in
                guard !mine, let i = Shortcuts.hint(for: .assignToMe) else {
                    return String(localized: "\(a) to assign to…")
                }
                return String(localized: "\(i) to set myself, \(a) to…")
            }
        ) {
            Button {
                showAssign = true
            } label: {
                HStack(spacing: 6) {
                    Avatar(user: issue.fields.assignee, size: 20).accessibilityHidden(true)  // the text beside it says the same
                    Text(issue.fields.assignee?.displayName ?? String(localized: "Unassigned")).foregroundStyle(
                        issue.fields.assignee == nil ? .secondary : .primary)
                }
            }
            .buttonStyle(.plain)
            .editable()
            .pageTarget(PageTarget.assignee, in: pageReveal)
            .popover(isPresented: $showAssign, arrowEdge: embedded ? .bottom : .leading) {
                PeoplePicker(scope: .issue(key), current: issue.fields.assignee) { user in
                    showAssign = false
                    run { try await $0.assign(key, to: user?.accountId) }
                }
            }
        }
    }

    @ViewBuilder private func reporterField(_ issue: Issue) -> some View {
        field("Reporter") {
            HStack(spacing: 6) {
                Avatar(user: issue.fields.reporter, size: 20)
                Text(issue.fields.reporter?.displayName ?? "—")
            }
        }
    }

    @ViewBuilder private func fields(_ issue: Issue) -> some View {
        field("Type") {
            let types = store.issueTypes
            if !types.isEmpty {
                Menu {
                    ForEach(types) { t in
                        Toggle(
                            isOn: Binding(
                                get: { t.id == issue.fields.issuetype.id },
                                set: { on in
                                    if on {
                                        run {
                                            try await $0.editIssue(
                                                key, fields: ["issuetype": .object(["id": .string(t.id)])])
                                        }
                                    }
                                })
                        ) { Text(t.name) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        RemoteImage(url: issue.fields.issuetype.iconUrl).frame(width: 14, height: 14)
                        Text(issue.fields.issuetype.name)
                    }
                    .accessibilityLabel("Type: \(issue.fields.issuetype.name)")
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                .editable()
            } else {
                Text(issue.fields.issuetype.name)
            }
        }
        field("Parent") {
            Group {
                if let p = issue.fields.parent {
                    // Click goes to the parent, ⌘-click opens it beside; changing it is on the menu.
                    Button {
                        open(p.key)
                    } label: {
                        HStack(spacing: 6) {
                            RemoteImage(url: p.fields.issuetype?.iconUrl).frame(width: 14, height: 14)
                            Text(p.key).font(.callout.monospaced())
                            Text(p.fields.summary).lineLimit(1)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .editable()
                    .help("Open \(p.key); ⌘-click for a new window")
                    .contextMenu {
                        Button("Open", systemImage: "arrow.forward") {
                            open(IssueTarget(accountID: target.accountID, key: p.key))
                        }
                        Button("Open in New Window", systemImage: "macwindow.badge.plus") { openWindow(p.key) }
                        if store.canEdit("parent") {
                            Divider()
                            Button("Replace…", systemImage: "arrow.triangle.2.circlepath") { showParent = true }
                            Button("Remove", systemImage: "minus.circle", role: .destructive) { setParent(nil) }
                        }
                    }
                } else {
                    Button {
                        showParent = true
                    } label: {
                        Text("None").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.canEdit("parent"))
                    .editable(store.canEdit("parent"))
                }
            }
            .popover(isPresented: $showParent, arrowEdge: .leading) {
                ParentPicker(
                    key: key, current: issue.fields.parent?.key,
                    jql:
                        "project = \"\(issue.fields.project?.key ?? "")\" AND \(jira?.client.levelJQL((issue.fields.issuetype.hierarchyLevel ?? 0) + 1) ?? "") ORDER BY updated DESC"
                ) { new in
                    showParent = false
                    setParent(new)
                }
            }
        }
        // Sprint, due date and points rows are there from the first frame: a site that has the field shows the
        // row, and the menu wakes up once the edit screen is known. Nothing moves when it arrives.
        if store.canEdit(jira?.client.sprintField), !store.sprints.isEmpty {
            field("Sprint") {
                Menu {
                    Button("No Sprint") { setSprint(nil) }
                    ForEach(store.sprints) { s in
                        Button {
                            setSprint(s.id)
                        } label: {
                            if s.id == issue.activeSprint?.id {
                                Label(s.name, systemImage: "checkmark")
                            } else {
                                Text(s.name)
                            }
                        }
                    }
                } label: {
                    Text(issue.activeSprint?.name ?? String(localized: "None")).foregroundStyle(
                        issue.activeSprint == nil ? .secondary : .primary)
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                .editable()
            }
        } else if jira?.client.sprintField != nil,
            issue.fields.project?.projectTypeKey == "software" || issue.activeSprint != nil
        {
            field("Sprint") {
                Text(issue.activeSprint?.name ?? String(localized: "None")).foregroundStyle(
                    issue.activeSprint == nil ? .secondary : .primary)
            }
        }
        let due = issue.fields.duedate.flatMap(DueDate.parse)
        if due != nil || store.canEdit("duedate") || store.editMeta == nil {
            field("Due") {
                Button {
                    showDueDate = true
                } label: {
                    let overdue =
                        due.map { $0 < Calendar.current.startOfDay(for: .now) } == true
                        && issue.fields.status.statusCategory.key != "done"
                    Text(due?.formatted(date: .abbreviated, time: .omitted) ?? String(localized: "None"))
                        .foregroundStyle(
                            due == nil
                                ? AnyShapeStyle(.secondary) : overdue ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                }
                .buttonStyle(.plain)
                .disabled(!store.canEdit("duedate"))
                .editable(store.canEdit("duedate"))
                .popover(isPresented: $showDueDate, arrowEdge: .leading) {
                    DueDatePicker(date: due) { new in
                        showDueDate = false
                        run {
                            try await $0.editIssue(
                                key, fields: ["duedate": new.map { .string(DueDate.string($0)) } ?? .null])
                        }
                    }
                }
            }
        }
        if let pf = store.pointsField(jira?.client) {
            field("Story Points") {
                Menu {
                    Button("None") { run { try await $0.editIssue(key, fields: [pf: .null]) } }
                    ForEach([0, 0.5, 1, 2, 3, 5, 8, 13, 21], id: \.self) { (n: Double) in
                        Button(n.formatted()) { run { try await $0.editIssue(key, fields: [pf: .number(n)]) } }
                    }
                } label: {
                    Text(issue.points?.formatted() ?? String(localized: "None")).foregroundStyle(
                        issue.points == nil ? .secondary : .primary)
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                .editable()
            }
        } else if issue.points != nil || !(jira?.client.pointsFields.isEmpty ?? true) {
            field("Story Points") {
                Text(issue.points?.formatted() ?? String(localized: "None")).foregroundStyle(
                    issue.points == nil ? .secondary : .primary)
            }
        }
        multiValue("Components", field: "components", current: issue.fields.components ?? [])
        multiValue("Fix Versions", field: "fixVersions", current: issue.fields.fixVersions ?? [])
        if let w = issue.fields.watches {
            field(
                "Watchers",
                hint: hint(.watch) {
                    w.isWatching ? String(localized: "\($0) to unwatch") : String(localized: "\($0) to watch")
                }
            ) {
                Button {
                    showWatchers = true
                } label: {
                    Label("\(w.watchCount) watching", systemImage: w.isWatching ? "eye.fill" : "eye")
                        .foregroundStyle(w.isWatching ? Color.accentColor : .primary)
                        .inactiveDim()
                }
                .buttonStyle(.plain)
                .editable()
                .help("Who is watching; right-click to watch or unwatch")
                .contextMenu { watchToggle(w) }
                .popover(isPresented: $showWatchers, arrowEdge: .leading) {
                    WatchersView(key: key) { watchToggle(w) }
                }
            }
        }
        if let c = issue.fields.created { field("Created") { Text(c.formatted(date: .abbreviated, time: .shortened)) } }
        if let u = issue.fields.updated {
            field("Updated") { Text(u.formatted(.relative(presentation: .named))).help(u.formatted()) }
        }
    }

    private func watchToggle(_ w: Watches) -> some View {
        Button(
            w.isWatching ? "Unwatch" : "Watch",
            systemImage: w.isWatching ? "eye.slash" : "eye"
        ) {
            perform(.watch)
        }
    }

    /// Components and fix versions: a menu of checkable values when editable, else just the names.
    @ViewBuilder
    private func multiValue(_ name: LocalizedStringKey, field id: String, current: [NamedRef]) -> some View {
        let options = store.options(id)
        let selected = Set(current.map(\.id))
        let label = Text(
            current.isEmpty
                ? String(localized: "None") : current.map(\.name).formatted(.list(type: .and, width: .narrow))
        )
        .foregroundStyle(current.isEmpty ? .secondary : .primary)
        if !options.isEmpty {
            field(name) {
                Menu {
                    ForEach(options) { o in
                        Toggle(
                            o.name,
                            isOn: Binding(
                                get: { selected.contains(o.id) },
                                set: { on in
                                    let ids = on ? selected.union([o.id]) : selected.subtracting([o.id])
                                    run {
                                        try await $0.editIssue(
                                            key, fields: [id: .array(ids.sorted().map { .object(["id": .string($0)]) })]
                                        )
                                    }
                                }))
                    }
                } label: {
                    label
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                .editable()
            }
        } else if !current.isEmpty {
            field(name) { label }
        }
    }

    private func priorityLabel(_ p: Priority?) -> some View {
        HStack(spacing: 6) {
            if let p {
                PriorityIcon(priority: p).accessibilityHidden(true)
                Text(p.name)
            } else {
                Text("None").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Sections

    private func attachments(_ atts: [Attachment]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], alignment: .leading, spacing: 10) {
            ForEach(atts) { a in
                AttachmentTile(attachment: a) { url in store.previewURL = url }
                    .contextMenu {
                        Button("Quick Look", systemImage: "eye") { preview(a) }
                        Button("Open", systemImage: "arrow.up.forward.app") {
                            if let c = jira?.client { Task { await AttachmentOpener.open(a, client: c) } }
                        }
                        Button("Copy", systemImage: "doc.on.doc") {
                            if let c = jira?.client { Task { await AttachmentOpener.copy(a, client: c) } }
                        }
                        Button("Save As…", systemImage: "square.and.arrow.down") { saveAs(a) }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            // The bytes first, so the Bin can upload them again.
                            let account = target.accountID
                            run { c in
                                let data = try await c.data(for: a.content)
                                try await c.deleteAttachment(id: a.id)
                                await Bin.shared.put(
                                    .attachment(filename: a.filename, file: Bin.store(data, a.filename)),
                                    account: account, key: key)
                            }
                        }
                    }
            }
        }
    }

    /// One line per related issue: icon, key, title, then the status and the assignee in a column at the end,
    /// as in the list. A ref carries no assignee; the full record, once prefetched, does.
    private func relatedRow(_ key: String, icon: URL?, summary: String, status: Status?, assignee: JiraUser?)
        -> some View
    {
        Button {
            open(key)
        } label: {
            HStack(spacing: 8) {
                RemoteImage(url: icon).frame(width: 14, height: 14)
                Text(key).font(.callout.monospaced()).foregroundStyle(.secondary)
                Text(summary).lineLimit(1)
                Spacer()
                if let status { StatusPill(status: status) }
                Avatar(user: assignee, size: 16)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func refs(_ refs: [IssueRef]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(refs) { r in
                relatedRow(
                    r.key, icon: r.fields.issuetype?.iconUrl, summary: r.fields.summary, status: r.fields.status,
                    assignee: store.related[r.key]?.fields.assignee)
            }
        }
    }

    private func children(_ issues: [Issue]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(issues) { i in
                relatedRow(
                    i.key, icon: i.fields.issuetype.iconUrl, summary: i.fields.summary, status: i.fields.status,
                    assignee: i.fields.assignee)
            }
        }
    }

    private func linksList(_ links: [IssueLink]) -> some View {
        let grouped = Dictionary(grouping: links, by: \.relation)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(grouped.keys.sorted(), id: \.self) { relation in
                VStack(alignment: .leading, spacing: 4) {
                    Text(relation).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(grouped[relation] ?? []) { link in
                        if let o = link.other {
                            relatedRow(
                                o.key, icon: o.fields.issuetype?.iconUrl, summary: o.fields.summary,
                                status: o.fields.status, assignee: store.related[o.key]?.fields.assignee
                            )
                            .contextMenu {
                                Button("Remove Link", systemImage: "link.badge.minus", role: .destructive) {
                                    // `link(type:from:to:)` reads "from <outward> to": this issue is `from`
                                    // when its side of the link carries the outward wording.
                                    let account = target.accountID
                                    let (from, to) = link.outwardIssue != nil ? (key, o.key) : (o.key, key)
                                    run {
                                        try await $0.deleteLink(id: link.id)
                                        await Bin.shared.put(
                                            .link(type: link.type.name, from: from, to: to), account: account, key: key)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// "• 1d 7h logged • 3h remaining", in the title's weight: the time sits with the work log, not among the
    /// fields. The total only when two or more people logged time; with one, their group shows the same sum.
    private func worklogTotals(_ issue: Issue, _ logs: [Worklog]) -> String? {
        let tt = issue.fields.timetracking
        var parts: [String] = []
        if WorklogGroup.make(logs).count > 1 {
            parts.append(String(localized: "\(LogWorkView.format(logs.reduce(0) { $0 + $1.timeSpentSeconds })) logged"))
        }
        // Remaining means something only against an estimate; without one Jira reports "0m remaining".
        if let o = tt?.originalEstimate {
            if logs.isEmpty {
                parts.append(String(localized: "\(o) estimated"))
            } else if let r = tt?.remainingEstimate {
                parts.append(String(localized: "\(r) remaining"))
            }
        }
        return parts.isEmpty ? nil : parts.map { "• " + $0 }.joined(separator: " ")
    }

    /// Grouped by person: who logged how long, each person's entries folded under it until opened.
    private func worklogs(_ logs: [Worklog]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(WorklogGroup.make(logs)) { g in
                // Remembered as opened, since folded is where a group starts.
                let open = fold("\(shownKey)|worklog-open|\(g.id)")
                Foldable(collapsed: Binding(get: { !open.wrappedValue }, set: { open.wrappedValue = !$0 }), gap: 6) {
                    HStack(spacing: 10) {
                        Avatar(user: g.author, size: 26)  // the comments' size
                        Text(g.author?.displayName ?? String(localized: "Unknown")).font(.callout.weight(.semibold))
                        Text(verbatim: LogWorkView.format(g.seconds)).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Disclosure(collapsed: !open.wrappedValue)
                    }
                } content: {
                    // Lazy, as the comments: one person can have hundreds of entries.
                    LazyVStack(alignment: .leading, spacing: 6) { ForEach(g.logs) { w in worklogRow(w) } }
                }
            }
        }
    }

    private func worklogRow(_ w: Worklog) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("logged \(w.timeSpent)").font(.callout)
                    Text(w.started.formatted(date: .abbreviated, time: .omitted)).font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let c = w.comment, !c.plainText.isEmpty {
                    Text(c.plainText).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if w.author?.accountId == jira?.me?.accountId {
                DeleteButton(help: "Delete work log") {
                    let account = target.accountID
                    run {
                        try await $0.deleteWorklog(key, id: w.id)
                        await Bin.shared.put(
                            .worklog(seconds: w.timeSpentSeconds, comment: w.comment, started: w.started),
                            account: account, key: key)
                    }
                }
            }
        }
        .padding(.leading, 36)  // under the name, past the avatar
    }

    /// "Comments • 250 comments • newest first ↓ • M to add". The order is a click on it, as the list's "sorted by".
    private func commentsCard(_ issue: Issue) -> some View {
        let count = issue.fields.comment?.total ?? 0
        return GlassCard(
            title: "Comments", detail: count > 0 ? "• " + String(localized: "\(count) comments") : nil,
            accessory: count > 1
                ? AnyView(
                    Button {
                        newestFirst.toggle()
                    } label: {
                        HStack(spacing: 2) {
                            Text(
                                verbatim: "• "
                                    + (newestFirst
                                        ? String(localized: "newest first") : String(localized: "oldest first")))
                            Image(systemName: newestFirst ? "arrow.down" : "arrow.up").font(.caption2.weight(.bold))
                        }
                        .font(.subheadline).foregroundStyle(.secondary).contentShape(.rect)
                    }
                    .buttonStyle(.plain).help("Sort order")) : nil,
            hint: hint(.comment) { String(localized: "\($0) to add") },
            collapsed: fold("\(shownKey)|comments")
        ) { comments(issue) }
        .id("comments")
    }

    private func comments(_ issue: Issue) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            let list = issue.fields.comment?.comments ?? []
            // The composer sits at the newest end: above the thread newest first, below it oldest first.
            if newestFirst {
                commentComposer()
                Divider()
            }
            if store.isPartial {
                DelayedSpinner()
            } else if list.isEmpty {
                Text("No comments yet").foregroundStyle(.tertiary)
            }
            // AppKit: rows reused as they scroll, text laid out once, so a thread of a thousand comments scrolls at
            // the display's rate (see CommentThread.swift).
            if !list.isEmpty {
                CommentThread(
                    comments: newestFirst ? list.reversed() : list, attachments: issue.fields.attachment ?? [],
                    meID: jira?.me?.accountId, editingID: editingCommentID,
                    editor: { c, focus in AnyView(commentEditor(c, focus: focus)) },
                    onEdit: beginCommentEdit, onDelete: deleteComment, onPreview: preview, loadImage: loadImage,
                    client: jira?.client)
            }
            if !newestFirst {
                Divider()
                commentComposer()
            }
        }
    }

    /// The editor on one comment, hosted in its AppKit row: the environment it needs goes with it.
    private func commentEditor(_ c: Comment, focus: FocusState<Bool>.Binding) -> some View {
        Composer(
            text: $editDraft, mentions: $editMentions, placeholder: "Edit comment", uploadImage: uploadPasted,
            focus: focus,
            actions: AnyView(
                HStack(spacing: 10) {
                    Button("Cancel") { cancelCommentEdit() }.glassButton().keyboardShortcut(.cancelAction)
                    Button("Save") { saveCommentEdit(c) }.glassButton(prominent: true)
                        .keyboardShortcut(focus.wrappedValue ? KeyboardShortcut(.return, modifiers: .command) : nil)
                        .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                })
        )
        .environment(session)
        .environment(\.jira, jira)
        .environment(\.adfAttachments, store.issue?.fields.attachment ?? [])
        .environment(\.previewURL, $store.previewURL)
    }

    /// An image from memory, disk or the site for the thread's rows, as `RemoteImage` and `InlineImage` load theirs.
    private func loadImage(_ url: URL, maxPixels: Int) async -> NSImage? {
        if let hit = ImageCache.shared.object(forKey: url as NSURL) { return hit }
        if let data = await DiskCache.imageData(for: url),
            let img = await DiskCache.decodeImage(data, maxPixels: maxPixels)
        {
            ImageCache.shared.setObject(img, forKey: url as NSURL)
            return img
        }
        guard let client = session.client(for: url), let data = try? await client.data(for: url),
            let img = await DiskCache.decodeImage(data, maxPixels: maxPixels)
        else { return nil }
        DiskCache.saveImage(data, for: url)
        ImageCache.shared.setObject(img, forKey: url as NSURL)
        return img
    }

    private func commentComposer() -> some View {
        CommentComposer(
            target: target, disabled: store.isWorking || editingCommentID != nil, focusRequest: commentRequest,
            uploadImage: uploadPasted, focus: $commentFocused
        ) { doc in
            await run { try await $0.addComment(key, body: doc) }.value
        }
        .pageTarget(PageTarget.composer, in: pageReveal)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // The preview column's Back sits with its actions; a split view would put a .navigation item at the
        // window's leading edge, over the list.
        if embedded {
            ToolbarItem {
                if let back {
                    Button(action: back) { Label("Back", systemImage: "chevron.backward") }
                        .help("Back to the previous issue (⌘[)")
                        .keyboardShortcut("[", modifiers: .command)
                }
            }
        }
        // A window's title is the crumb, with Back before it (see WindowTitle).
        if !embedded {
            ToolbarItem(placement: .navigation) {
                // A new window has no issue yet: the list's copy names the parent and type, so the title is whole
                // from the first frame instead of growing a parent half a second later.
                WindowTitle(
                    issue: store.issue ?? jira?.peek[key], key: key, back: back, forward: forward, open: open)
            }
            .glassTitle()
        }
        ToolbarItem {
            Button {
                perform(.refresh)
            } label: {
                // While a write or a refresh runs, the button is the spinner, then the arrow again. Symbols, not a
                // ProgressView: a custom view took the button out of its glass group. Both always laid out, so the
                // button keeps the wider one's width and nothing beside it moves.
                let busy = store.isWorking || refreshing
                Label {
                    Text("Refresh")
                } icon: {
                    ZStack {
                        Image(systemName: "progress.indicator").opacity(busy ? 1 : 0)
                            .symbolEffect(.variableColor.iterative.dimInactiveLayers.nonReversing, isActive: busy)
                        Image(systemName: "arrow.clockwise").opacity(busy ? 0 : 1)
                    }
                }
            }
            .help("Refresh (⇧⌘R)")
        }
        // A window's history sits with Refresh; the preview keeps it on the Description card.
        if !embedded {
            ToolbarItem {
                Button {
                    perform(.history)
                } label: {
                    Label("Activity History", systemImage: "clock.arrow.circlepath")
                }
                .help("Activity history (⌥⌘H)")
                .disabled(store.issue == nil)
            }
        }
        // The Issue menu's actions, one click each, in one group; Copy Link and Open in Browser stay in the menu
        // (⇧⌘C, ⇧⌘O). In the preview the group sits centred between Refresh and the search field.
        if #available(macOS 26, *) {
            ToolbarSpacer(embedded ? .flexible : .fixed)
        } else if embedded {
            ToolbarItem { Spacer() }
        }
        actionItems  // the search field after it brings its own flexible space
    }

    /// Attach and the Issue menu's actions that open a form, one click each.
    @ToolbarContentBuilder private var actionItems: some ToolbarContent {
        ToolbarItem {
            Button {
                attachFiles()
            } label: {
                Label("Attach Files", systemImage: "paperclip")
            }
            .help("Attach files (⌥⌘A). You can also drop them anywhere or paste an image.")
            .disabled(store.issue == nil)
        }
        ToolbarItem {
            Button {
                perform(.subtask)
            } label: {
                Label("Create Subtask…", systemImage: "plus.square.on.square")
            }
            .help("Create subtask (⇧⌘N)")
            .disabled(store.issue == nil)
        }
        ToolbarItem {
            Button {
                showLink = true
            } label: {
                Label("Link Issue…", systemImage: "link")
            }
            .help("Link issue (⇧⌘L)")
            .disabled(store.issue == nil)
            .popover(isPresented: $showLink, arrowEdge: .bottom) {
                LinkIssueView(key: key, types: store.linkTypes) { type, outward, inward in
                    showLink = false
                    run { try await $0.link(type: type, from: outward, to: inward) }
                }
            }
        }
        ToolbarItem {
            Button {
                showLogWork = true
            } label: {
                Label("Log Work…", systemImage: "clock")
            }
            .help("Log work (⌥⌘L)")
            .disabled(store.issue == nil)
            .popover(isPresented: $showLogWork, arrowEdge: .bottom) {
                LogWorkView { seconds, comment, started in
                    showLogWork = false
                    let estimated =
                        store.issue?.fields.timetracking.map {
                            $0.originalEstimate != nil || $0.remainingEstimate != nil
                        } ?? false
                    run {
                        try await $0.addWorklog(
                            key, seconds: seconds, comment: comment.isEmpty ? nil : .document(markdown: comment),
                            started: started, adjustsEstimate: estimated)
                    }
                }
            }
        }
        ToolbarItem {
            Button {
                showRemind = true
            } label: {
                Label("Remind Me…", systemImage: "bell")
            }
            .help("Remind me (⌥⌘R)")
            .disabled(store.issue == nil)
            .popover(isPresented: $showRemind, arrowEdge: .bottom) {
                if let url = jira?.client.browseURL(key) {
                    ReminderView(url: url, key: key, summary: store.issue?.fields.summary ?? "") { showRemind = false }
                }
            }
        }
    }

    // MARK: Actions

    private var actions: IssueActions? {
        guard let issue = store.issue else { return nil }
        return IssueActions(
            key: key,
            watching: issue.fields.watches?.isWatching == true,
            assignedToMe: issue.fields.assignee?.accountId != nil
                && issue.fields.assignee?.accountId == jira?.me?.accountId,
            transitions: store.transitions,
            canEditSummary: store.canEdit("summary"),
            canEditDescription: store.canEdit("description"),
            isEditing: summaryDraft != nil || descriptionDraft != nil || editingCommentID != nil,
            back: back,
            embedded: embedded,
            perform: perform
        )
    }

    private func perform(_ action: IssueActions.Action) {
        guard let jira else { return }
        let summary = store.issue?.fields.summary ?? ""
        switch action {
        case .openInBrowser: NSWorkspace.shared.open(jira.client.browseURL(key))
        case .openInWindow: openWindow(id: "issue", value: target)
        case .copyLink: copyToPasteboard(jira.client.browseURL(key).absoluteString)
        case .copyKey: copyToPasteboard(key)
        case .assign: reveal(.assignee, .middle) { showAssign = true }
        case .assignToMe:
            let me = jira.me?.accountId
            run { try await $0.assign(key, to: me) }
        case .changeStatus: reveal(.status, .middle) { showStatus = true }
        case .changePriority: reveal(.priority, .middle) { showPriority = true }
        case .editLabels: reveal(.labels, .middle) { showLabels = true }
        case .watch:
            let on = store.issue?.fields.watches?.isWatching != true
            let me = jira.me?.accountId
            run { try await $0.watch(key, on, me: me) }
        case .transition(let id): transition(id)
        case .remind: showRemind = true
        // An editor already open keeps its draft and only takes the keyboard back: starting over dropped the typing.
        case .editSummary:
            reveal(.summary, .start) {
                guard summaryDraft == nil else { return refocus($summaryFocused) }
                caretPending = true
                summaryDraft = summary
            }
        case .editDescription:
            guard let issue = store.issue else { return }
            reveal(.description, .start) {
                guard descriptionDraft == nil else { return refocus($descriptionFocused) }
                beginDescriptionEdit(issue)
            }
        case .comment:
            // A folded thread opens first, so there is a box to write in.
            let thread = fold("\(shownKey)|comments")
            let opening = thread.wrappedValue
            thread.wrappedValue = false
            Task {
                if opening { try? await Task.sleep(for: .milliseconds(300)) }
                reveal(.composer, .middle) { commentRequest += 1 }
            }
        case .attach: attachFiles()
        case .link: showLink = true
        case .logWork: showLogWork = true
        case .subtask:
            openWindow(
                id: "create",
                value: CreateRequest(
                    accountID: target.accountID, projectKey: store.issue?.fields.project?.key, parentKey: key))
        case .clone:
            openWindow(
                id: "create",
                value: CreateRequest(
                    accountID: target.accountID, projectKey: store.issue?.fields.project?.key, cloneKey: key))
        case .refresh:
            Task {
                refreshing = true
                await store.load(jira, key: key)
                refreshing = false
            }
        case .history: openWindow(id: "history", value: target)
        }
    }

    /// The task resolves to whether the write succeeded, so editors can keep a draft that failed to save.
    @discardableResult
    private func run(_ op: @escaping @Sendable (JiraClient) async throws -> Void) -> Task<Bool, Never> {
        guard let jira else { return Task { false } }
        let key = key
        return Task {
            let ok = await store.perform(jira, key: key, op)
            if ok {
                ownLoad = "\(key)|\(session.reloadTick)|\((session.writeTicks[key] ?? 0) + 1)"
                session.writeTicks[key, default: 0] += 1
                session.listTick += 1
            }
            return ok
        }
    }

    /// Shows `change` at once and writes it; the page waits for nobody. A failed write puts the old issue back.
    @discardableResult
    private func optimistic(
        _ change: (inout Issue.Fields) -> Void, _ op: @escaping @Sendable (JiraClient) async throws -> Void
    )
        -> Task<Bool, Never>
    {
        let before = store.issue
        if var f = before?.fields {
            change(&f)
            store.issue?.fields = f
        }
        let task = run(op)
        Task { if !(await task.value), store.key == before?.key { store.issue = before } }
        return task
    }

    private func transition(_ id: String) {
        guard let t = store.transitions.first(where: { $0.id == id }), let old = store.issue?.fields.status else {
            return
        }
        let account = target.accountID
        optimistic({ $0.status = t.to }) {
            try await $0.transition(key, to: id)
            await Bin.shared.put(.status(old), account: account, key: key)
        }
    }

    /// Sets, replaces or removes the parent; the old one goes to the Bin.
    private func setParent(_ new: String?) {
        let old = store.issue?.fields.parent?.key
        let subtask = store.issue?.fields.issuetype.isSubtask == true
        let account = target.accountID
        run {
            try await $0.editIssue(key, fields: $0.parentFields(new, subtask: subtask))
            await Bin.shared.put(.parent(old), account: account, key: key)
        }
    }

    /// Puts the caret under the click that opened the editor, or at the end when a key opened it (⌘E).
    /// Focus selects everything; this runs inside that selection change, so no frame ever shows it.
    /// The editor sits where the text was, in the same font, so the character under the point is the one clicked.
    /// AppKit hangs the summary's field editor in a focus clip view whose bounds can start half a point off its frame
    /// (when SwiftUI rounded the field's height under its text's), which drew the text half a point above the title it
    /// replaced. Called on every selection change, as typing a new line lays the clip view out again.
    private func alignSummaryEditor(_ tv: NSTextView?) {
        guard summaryDraft != nil, let tv, tv.isFieldEditor, tv.window?.firstResponder === tv, let clip = tv.superview,
            (clip.superview as? NSTextField)?.cell?.wraps == true, clip.bounds.origin != clip.frame.origin
        else { return }
        clip.setBoundsOrigin(clip.frame.origin)
    }

    private func placeCaret(in tv: NSTextView?) {
        guard caretPending, let tv, let window = tv.window, window.isKeyWindow, window.firstResponder === tv,
            tv.selectedRange().length == (tv.string as NSString).length, tv.selectedRange().length > 0
        else { return }
        caretPending = false
        var index = (tv.string as NSString).length
        if let at = editClick {
            let local = tv.convert(window.convertPoint(fromScreen: at), from: nil)
            index = tv.characterIndexForInsertion(at: local)
        }
        editClick = nil
        tv.setSelectedRange(NSRange(location: index, length: 0))
    }

    /// ↩ saves and hands the keyboard back. `blurred`: the keyboard went elsewhere on the page and stays there, and an
    /// emptied field goes back to the title as it was.
    private func saveSummary(blurred: Bool = false) {
        guard let draft = summaryDraft?.trimmingCharacters(in: .whitespacesAndNewlines), !draft.isEmpty else {
            if blurred { summaryDraft = nil }
            return
        }
        guard draft.count <= 255 else {
            store.error = String(localized: "A summary can be 255 characters at most; this one is \(draft.count).")
            return
        }
        summaryDraft = nil
        if !blurred { returnKeyboard() }
        guard draft != store.issue?.fields.summary else { return }
        let key = key
        Task {
            if !(await optimistic({ $0.summary = draft }) {
                try await $0.editIssue(key, fields: ["summary": .string(draft)])
            }.value), self.key == key {
                summaryDraft = draft
            }
        }
    }

    /// Leaving for another issue commits an open summary edit, as Finder commits a rename and Jira a blurred field,
    /// instead of dropping it. Empty or too long is dropped: there is no page left to complain on.
    private func commitSummary(of old: IssueTarget) {
        // The old issue's own account: the page may have moved to an issue of another one.
        guard let client = session.state(old.accountID)?.client,
            let draft = summaryDraft?.trimmingCharacters(in: .whitespacesAndNewlines), !draft.isEmpty,
            draft.count <= 255, draft != store.issue?.fields.summary
        else { return }
        let key = old.key
        Task {
            do {
                try await client.editIssue(key, fields: ["summary": .string(draft)])
                session.writeTicks[key, default: 0] += 1
                session.listTick += 1
            } catch {
                if !error.isCancelled { store.error = error.localizedDescription }
            }
        }
    }

    private func editOnWeb(_ url: URL) -> AttributedString {
        var s = AttributedString(localized: "Edit on the web")
        s.link = url
        return s
    }

    /// A click on a task's circle flips it, in Jira too. Cloud only: wiki markup has no task lists.
    private func toggleTask(_ localId: String) {
        guard var doc = store.issue?.fields.description else { return }
        doc.flipTask(localId)
        guard let value = try? JSONValue(doc) else { return }
        _ = optimistic({ $0.description = doc }) { try await $0.editIssue(key, fields: ["description": value]) }
    }

    /// Focus an editor whose focus state may be true already while the keyboard is elsewhere.
    private func refocus(_ focus: FocusState<Bool>.Binding) {
        focus.wrappedValue = false
        DispatchQueue.main.async { focus.wrappedValue = true }
    }

    /// `PageReveal.reveal` on this page; the action is dropped when another issue came in meanwhile.
    private func reveal(
        _ target: PageTarget, _ placement: PageReveal.Placement, then action: @escaping @MainActor () -> Void
    ) {
        let shown = store.issue?.key
        // The preview's status, assignee and priority sit in a lazy grid: off screen they have no frame, their card has.
        let card: [PageTarget] = [.status, .assignee, .priority].contains(target) ? [.fields] : []
        pageReveal.reveal([target] + card, placement) { if store.issue?.key == shown { action() } }
    }

    private func beginDescriptionEdit(_ issue: Issue) {
        var mentions: [String: String] = [:]
        descriptionDraft = issue.fields.description?.markdown(mentions: &mentions) ?? ""
        descriptionOriginal = descriptionDraft ?? ""
        descriptionMentions = mentions
    }

    /// Escape or Cancel closes at once, no question asked: a draft is only ever lost by this deliberate step,
    /// never by a switch to another issue or a relaunch.
    private func cancelDescriptionEdit() {
        descriptionDraft = nil
        returnKeyboard()
    }

    /// A closed editor hands the keyboard back to where the arrows work: the list beside the preview, or the page
    /// in a window of its own. Left on the editor that just went away, it went nowhere and the arrows did nothing.
    private func returnKeyboard() {
        DispatchQueue.main.async { NSApp.keyWindow?.focusList() }
    }

    private func saveDescription() {
        guard let draft = descriptionDraft else { return }
        descriptionDraft = nil
        returnKeyboard()
        guard draft != descriptionOriginal else { return }
        let doc = ADFNode.document(markdown: draft, mentions: descriptionMentions)
        guard let value = try? JSONValue(doc) else { return }
        Task {
            if !(await optimistic({ $0.description = doc }) {
                try await $0.editIssue(key, fields: ["description": value])
            }
            .value) {
                descriptionDraft = draft
            }
        }
    }

    private func setSprint(_ id: Int?) {
        guard let field = jira?.client.sprintField else { return }
        run { try await $0.editIssue(key, fields: [field: id.map { .number(Double($0)) } ?? .null]) }
    }

    private func beginCommentEdit(_ c: Comment) {
        var mentions: [String: String] = [:]
        editDraft = c.body.markdown(mentions: &mentions)
        editOriginal = editDraft
        editMentions = mentions
        editingCommentID = c.id
    }

    private func cancelCommentEdit() {
        editingCommentID = nil
        returnKeyboard()
    }

    /// Deletes at once; the comment lands in the Bin.
    private func deleteComment(_ c: Comment) {
        let account = target.accountID
        run {
            try await $0.deleteComment(key, id: c.id)
            await Bin.shared.put(.comment(c.body), account: account, key: key)
        }
    }

    private func saveCommentEdit(_ c: Comment) {
        editingCommentID = nil
        returnKeyboard()
        guard editDraft != editOriginal else { return }
        let doc = ADFNode.document(markdown: editDraft, mentions: editMentions)
        Task {
            if !(await run { try await $0.updateComment(key, id: c.id, body: doc) }.value) { editingCommentID = c.id }
        }
    }

    private func preview(_ a: Attachment) {
        guard let c = jira?.client else { return }
        Task { if let url = await AttachmentOpener.download(a, client: c) { store.previewURL = url } }
    }

    private func saveAs(_ a: Attachment) {
        if let c = jira?.client { AttachmentOpener.saveAs(a, client: c) }
    }

    private func attachFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        upload(urls: panel.urls)
    }

    private func upload(urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        run { client in
            for url in files {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                try await client.uploadAttachment(key, data: data, filename: url.lastPathComponent)
            }
        }
    }

    private func pasteAttachment() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            upload(urls: urls)
            return
        }
        guard let image = PastedImage.read() else { return }
        run { try await $0.uploadAttachment(key, data: image.data, filename: image.name) }
    }

    /// For composers: the pasted image becomes an attachment, and the draft links to it.
    private func uploadPasted(_ data: Data, _ name: String) async throws -> URL {
        guard let jira else { throw CancellationError() }
        let uploaded = try await jira.client.uploadAttachment(key, data: data, filename: name)
        await store.load(jira, key: key, full: false)
        guard let url = uploaded.first?.content else { throw CancellationError() }
        return url
    }
}

// MARK: - Pieces

struct AttachmentTile: View {
    let attachment: Attachment
    var onPreview: (URL) -> Void
    @Environment(Session.self) private var session
    @State private var busy = false
    private var client: JiraClient? { session.client(for: attachment.content) }

    var body: some View {
        Button(action: preview) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    if attachment.thumbnail != nil {
                        // Behind a clear colour, so a wide thumbnail cannot widen the tile into its neighbour.
                        Color.clear.overlay { RemoteImage(url: attachment.thumbnail, fit: true) }.clipped()
                    } else {
                        Image(systemName: icon).font(.title).foregroundStyle(.secondary)
                    }
                    if busy { ProgressView().controlSize(.small) }
                }
                .frame(height: 90)
                .frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.4))
                .clipShape(.rect(cornerRadius: 10))
                Text(attachment.filename).font(.caption).lineLimit(1).truncationMode(.middle)
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("\(attachment.filename) — click to preview")
        // ponytail: a hover fetches files under 25 MB so a drag out has the file; a bigger one only drags once
        // it was previewed, opened or copied.
        .onHover { inside in
            guard inside, attachment.size < 25_000_000, let client else { return }
            Task { _ = await AttachmentOpener.download(attachment, client: client) }
        }
        .onDrag { AttachmentOpener.dragItem(attachment) ?? NSItemProvider() }
    }

    private var icon: String {
        let mime = attachment.mimeType ?? ""
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("video/") { return "film" }
        if mime.contains("zip") { return "doc.zipper" }
        if mime.contains("pdf") { return "doc.richtext" }
        return "doc"
    }

    private func preview() {
        guard let client, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            if let url = await AttachmentOpener.download(attachment, client: client) { onPreview(url) }
        }
    }
}

/// Owns the comment draft, so each keystroke re-evaluates this small view and not the whole issue page.
struct CommentComposer: View {
    let target: IssueTarget
    let disabled: Bool
    let focusRequest: Int
    let uploadImage: (Data, String) async throws -> URL
    var focus: FocusState<Bool>.Binding
    /// Posts the comment; true once Jira has it. The draft stays on failure.
    let send: (ADFNode) async -> Bool
    @State private var text = ""
    @State private var mentions: [String: String] = [:]

    var body: some View {
        Composer(
            text: $text, mentions: $mentions, placeholder: "Add a comment…  ⌘↩ to send", minHeight: 44,
            uploadImage: uploadImage, focus: focus,
            actions: AnyView(
                Button("Comment") { post() }
                    .glassButton(prominent: true)
                    // Only while this box has focus: the description and comment editors share the shortcut.
                    .keyboardShortcut(focus.wrappedValue ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || disabled))
        )
        .onChange(of: focusRequest) { focus.wrappedValue = true }
        // The draft is the issue's, on disk (see `Drafts`); the composer lives on from one issue to the next, so it
        // swaps its text by hand.
        .onAppear { load(target) }
        .onChange(of: target) { _, new in load(new) }
        .onChange(of: text) {
            Drafts.shared.update(target) {
                $0.comment = text
                $0.commentMentions = mentions
            }
        }
    }

    private func load(_ t: IssueTarget) {
        let d = Drafts.shared[t]
        (text, mentions) = (d.comment, d.commentMentions)
    }

    private func post() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let doc = ADFNode.document(markdown: body, mentions: mentions)
        Task {
            if await send(doc) {
                text = ""
                mentions = [:]
                focus.wrappedValue = false
                NSApp.keyWindow?.focusList()
            }
        }
    }
}

enum AttachmentOpener {
    private static func file(for attachment: Attachment) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "attachments/\(attachment.id)/\(attachment.filename)")
    }

    private static func store(_ data: Data, for attachment: Attachment) -> URL {
        let file = file(for: attachment)
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file)
        return file
    }

    /// Downloads with auth into the app's temp folder; the same file is reused on later calls.
    static func download(_ attachment: Attachment, client: JiraClient) async -> URL? {
        let file = file(for: attachment)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        // An inline image already has its bytes in the image cache; reuse them instead of fetching again.
        var data = await DiskCache.imageData(for: attachment.content)
        if data == nil { data = try? await client.data(for: attachment.content) }
        guard let data else { return nil }
        return store(data, for: attachment)
    }

    static func open(_ attachment: Attachment, client: JiraClient) async {
        if let file = await download(attachment, client: client) { NSWorkspace.shared.open(file) }
    }

    /// A save panel, then the bytes to where it says; a failed write is said in an alert.
    @MainActor static func saveAs(_ attachment: Attachment, client: JiraClient) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.filename
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        Task {
            do { try await client.data(for: attachment.content).write(to: dest) } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    static func type(_ attachment: Attachment) -> UTType {
        UTType(mimeType: attachment.mimeType ?? "")
            ?? UTType(filenameExtension: (attachment.filename as NSString).pathExtension) ?? .data
    }

    /// For a drag out of the app: the file, once it is here (downloaded, or shown inline from the image cache).
    /// SwiftUI turns a provider's file into a promise only when the file exists, so a tile fetches on hover.
    static func dragItem(_ attachment: Attachment) -> NSItemProvider? {
        var file = file(for: attachment)
        if !FileManager.default.fileExists(atPath: file.path) {
            guard let data = DiskCache.imageDataNow(for: attachment.content) else { return nil }
            file = store(data, for: attachment)
        }
        let p = NSItemProvider(contentsOf: file)
        p?.suggestedName = attachment.filename
        return p
    }

    /// The file onto the pasteboard, and a picture's bytes beside it: Finder pastes the file, an editor the picture.
    @MainActor static func copy(file: URL) {
        let item = NSPasteboardItem()
        item.setString(file.absoluteString, forType: .fileURL)
        if let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image),
            let data = try? Data(contentsOf: file)
        {
            item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    static func copy(_ attachment: Attachment, client: JiraClient) async {
        if let file = await download(attachment, client: client) { await copy(file: file) }
    }

    /// ⌘C while a Quick Look panel is up copies what it shows: the panel takes the keys, and nothing behind it
    /// knows what is on view.
    static func installQuickLookCopy() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                e.charactersIgnoringModifiers == "c"
            else { return e }
            let copied = MainActor.assumeIsolated {  // delivered on the main thread
                guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
                    panel.isKeyWindow, let url = panel.currentPreviewItem?.previewItemURL
                else { return false }
                copy(file: url)
                return true
            }
            return copied ? nil : e
        }
    }
}

/// A file promised to the drop target: the attachment downloads as it lands. Its own delegate, so the session
/// keeps it alive.
final class AttachmentPromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    private let attachment: Attachment
    private let client: JiraClient

    init(_ attachment: Attachment, client: JiraClient) {
        self.attachment = attachment
        self.client = client
        super.init()
        fileType = AttachmentOpener.type(attachment).identifier
        delegate = self
    }

    func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        attachment.filename
    }

    func filePromiseProvider(
        _ p: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void
    ) {
        nonisolated(unsafe) let done = completionHandler
        let attachment = attachment
        let client = client
        Task {
            guard let file = await AttachmentOpener.download(attachment, client: client) else {
                return done(CocoaError(.fileNoSuchFile))
            }
            do {
                try FileManager.default.copyItem(at: file, to: url)
                done(nil)
            } catch {
                done(error)
            }
        }
    }
}

struct ReminderView: View {
    let url: URL
    let key: String
    let summary: String
    var done: () -> Void
    @State private var date = Calendar.current.date(byAdding: .hour, value: 1, to: .now)!
    @State private var existing: Date?
    @State private var error: String?

    private var presets: [(String, Date)] {
        let cal = Calendar.current
        let tomorrow9 = cal.date(
            bySettingHour: 9, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: .now)!)!
        let monday9 = cal.nextDate(
            after: .now, matching: DateComponents(hour: 9, minute: 0, weekday: 2), matchingPolicy: .nextTime)!
        let at = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
        return [
            (String(localized: "In 1 Hour"), .now.addingTimeInterval(3600)),
            (String(localized: "Tomorrow at \(at(tomorrow9))"), tomorrow9),
            (String(localized: "Next Monday at \(at(monday9))"), monday9),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Remind Me").font(.headline)
            if let existing {
                HStack {
                    Label(existing.formatted(date: .abbreviated, time: .shortened), systemImage: "bell.fill").font(
                        .callout)
                    Spacer()
                    Button("Remove") {
                        Notifier.cancelReminder(for: url)
                        done()
                    }
                }
            }
            ForEach(presets, id: \.0) { title, at in
                Button(title) { set(at) }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
            Divider()
            HStack {
                DatePicker("At", selection: $date, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                Button("Set") { set(date) }.glassButton(prominent: true).keyboardShortcut(.defaultAction)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 280)
        .task { existing = await Notifier.reminder(for: url) }
    }

    private func set(_ at: Date) {
        Task {
            do {
                try await Notifier.remind(url, key: key, summary: summary, at: at)
                done()
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// Jira due dates are plain calendar days, read and written in the local calendar.
enum DueDate {
    private static let format: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func parse(_ s: String) -> Date? { format.date(from: s) }
    static func string(_ d: Date) -> String { format.string(from: d) }
}

struct DueDatePicker: View {
    @State private var date: Date
    private let hadDate: Bool
    var onSave: (Date?) -> Void

    init(date: Date?, onSave: @escaping (Date?) -> Void) {
        _date = State(initialValue: date ?? .now)
        hadDate = date != nil
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DatePicker("Due date", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical).labelsHidden()
                .focusEffectDisabled()  // the thick square ring around the whole calendar
            HStack {
                Button("Clear") { onSave(nil) }.glassButton().disabled(!hadDate)
                Spacer()
                Button("Save") { onSave(date) }.glassButton(prominent: true).keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }
}

struct LabelsEditor: View {
    @State var labels: [String]
    /// Every label on the site; the ones matching the draft are offered below the field.
    var suggestions: [String] = []
    var onSave: ([String]) -> Void
    @State private var draft = ""
    /// The match ↓ and ↑ walked to, which ↩ adds.
    @State private var highlighted: Int?
    @FocusState private var focused: Bool

    private var matches: [String] {
        let q = draft.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return suggestions.filter { $0.lowercased().contains(q) && !labels.contains($0) }.prefix(6).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Labels").font(.headline)
            if labels.isEmpty { Text("No labels").foregroundStyle(.tertiary).font(.callout) }
            Wrap { ForEach(labels, id: \.self) { l in Chip(text: l) { labels.removeAll { $0 == l } } } }
            TextField("New label · ↩ to add · ⌘↩ to save", text: $draft).textFieldStyle(.roundedBorder)
                .onSubmit(add).focused($focused)
                .onKeyPress(.downArrow) { step(1) }
                .onKeyPress(.upArrow) { step(-1) }
                // A comma ends a label, so several can be typed or pasted in one go.
                .onChange(of: draft) {
                    highlighted = nil
                    if draft.contains(",") { add() }
                }
            ForEach(Array(matches.enumerated()), id: \.element) { i, m in
                Button {
                    labels.append(m)
                    draft = ""
                } label: {
                    Text(m).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                }
                .buttonStyle(.plain).padding(.horizontal, 6).padding(.vertical, 3)
                .background(i == highlighted ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 6))
            }
            HStack {
                Spacer()
                Button("Save") {
                    add()
                    onSave(labels)
                }.glassButton(prominent: true).keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
        .frame(width: 280)
        .focusSoon($focused)
    }

    private func step(_ by: Int) -> KeyPress.Result {
        guard !matches.isEmpty else { return .ignored }
        highlighted = max(0, min(matches.count - 1, (highlighted ?? -1) + by))
        return .handled
    }

    private func add() {
        if let h = highlighted, matches.indices.contains(h) {
            labels.append(matches[h])
        } else {
            for l in draft.split(separator: ",") {
                let l = l.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
                if !l.isEmpty, !labels.contains(l) { labels.append(l) }
            }
        }
        draft = ""
    }
}

/// What a key acts on, on the issue page.
private enum PageTarget: Hashable {
    case summary, description, status, priority, assignee, labels, composer
    /// The preview column's card of status, assignee, priority and reporter, a lazy grid.
    case fields
}

/// A bin icon that deletes at once and asks nothing: what it deletes lands in the Bin (Window menu) to be put back.
struct DeleteButton: View {
    let help: LocalizedStringKey
    let perform: () -> Void

    var body: some View {
        Button(action: perform) { Label("Delete", systemImage: "trash").labelStyle(.iconOnly) }
            .buttonStyle(.plain).foregroundStyle(.tertiary).help(help)
    }
}

/// A popover of choices with the current one ticked, for what a key opens.
/// ponytail: Tab moves between rows; arrow keys and a type-to-find would be the next step.
struct PickList: View {
    let items: [(id: String, title: String, selected: Bool)]
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items, id: \.id) { item in
                Button {
                    pick(item.id)
                } label: {
                    HStack(spacing: 8) {
                        Text(item.title)
                        Spacer()
                        if item.selected { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(minWidth: 200)
    }
}

/// Who watches the issue, with the watch toggle under the list.
struct WatchersView<Toggle: View>: View {
    let key: String
    @ViewBuilder var toggle: Toggle
    @Environment(\.jira) private var jira
    @State private var users: [JiraUser]?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Watchers").font(.headline)
            if let users {
                ForEach(users) { u in
                    HStack(spacing: 6) {
                        Avatar(user: u, size: 20)
                        Text(u.displayName)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
            toggle.glassButton()
        }
        .padding(12)
        .frame(minWidth: 220, alignment: .leading)
        .task { users = (try? await jira?.client.watchers(key)) ?? [] }
    }
}

/// Sets or clears the parent: a key typed or picked from the search.
struct ParentPicker: View {
    /// The issue being re-parented, left out of the results; nil while creating one.
    var key: String?
    let current: String?
    /// Scope of the search: the same project, one hierarchy level up.
    var jql: String
    /// "Clone" when the New Issue window borrows the picker to copy an issue.
    var title: LocalizedStringKey = "Parent"
    var verb: LocalizedStringKey = "Set"
    var onSave: (String?) -> Void
    @Environment(\.jira) private var jira
    @State private var query = ""
    @State private var results: [IssuePickerResult.Item] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            TextField("Key or search", text: $query).textFieldStyle(.roundedBorder).focused($focused)
                // ↩ takes the typed key when the search found it, else the first result; an ineligible key stays put.
                .onSubmit {
                    let k = query.trimmingCharacters(in: .whitespaces).uppercased()
                    if let r = results.first(where: { $0.key == k }) ?? results.first { onSave(r.key) }
                }
            List(results) { r in
                Button {
                    onSave(r.key)
                } label: {
                    HStack(spacing: 8) {
                        Text(r.key).font(.callout.monospaced()).foregroundStyle(.secondary)
                        Text(r.summaryText ?? "").lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain).scrollContentBackground(.hidden).frame(height: 160)
            HStack {
                if current != nil { Button("Clear") { onSave(nil) }.glassButton() }
                Spacer()
                Button(verb) { if let r = results.first { onSave(r.key) } }.glassButton(prominent: true)
                    .disabled(results.isEmpty)
            }
        }
        .padding(12)
        .frame(width: 320)
        .focusSoon($focused)
        .task(id: query) {
            guard let c = jira?.client else { return }
            if query.isEmpty {
                // The picker answers nothing to an empty query; the scope's own search lists the candidates.
                let page = try? await c.search(jql: jql)
                results = (page?.issues ?? []).filter { $0.key != key }
                    .map { IssuePickerResult.Item(key: $0.key, summaryText: $0.fields.summary) }
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            results = ((try? await c.pickIssues(query: query, excluding: key, jql: jql)) ?? []).filter { $0.key != key }
        }
    }
}

struct LinkIssueView: View {
    let key: String
    let types: [LinkType]
    var onLink: (_ type: String, _ outward: String, _ inward: String) -> Void
    @Environment(\.jira) private var jira
    @State private var relation: String = ""
    @State private var query = ""
    @State private var results: [IssuePickerResult.Item] = []
    @State private var picked: IssuePickerResult.Item?
    @FocusState private var linkFocused: Bool

    /// Every link type offers both directions, worded from this issue's side; once when both wordings are identical.
    var relations: [(id: String, label: String, type: LinkType, outward: Bool)] {
        types.flatMap { t in [(t.id + ">", t.outward, t, true), (t.id + "<", t.inward, t, false)] }
            .filter { $0.outward || $0.type.inward != $0.type.outward }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Link \(key)").font(.headline)
            Picker("This issue", selection: $relation) {
                ForEach(relations, id: \.id) { Text($0.label).tag($0.id) }
            }
            TextField("Search issues by key or text", text: $query).textFieldStyle(.roundedBorder).focused($linkFocused)
                .onSubmit {
                    if picked == nil { picked = results.first }
                    link()
                }
                // ↓ and ↑ walk the results from the field, so ↩ links the one that is highlighted.
                .onKeyPress(.downArrow) { step(1) }
                .onKeyPress(.upArrow) { step(-1) }
            // Buttons rather than list selection: a click in a popover's List does not reliably select its row.
            List(results) { r in
                Button {
                    picked = r
                } label: {
                    HStack(spacing: 8) {
                        Text(r.key).font(.callout.monospaced()).foregroundStyle(.secondary)
                        Text(r.summaryText ?? "").lineLimit(1)
                        Spacer()
                        if picked == r { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .listRowBackground(picked == r ? Color.accentColor.opacity(0.15) : .clear)
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .frame(height: 180)
            HStack {
                Spacer()
                Button("Link") { link() }
                    .glassButton(prominent: true)
                    .disabled(picked == nil || relation.isEmpty)
            }
        }
        .padding(12)
        .frame(width: 360)
        .onAppear { if relation.isEmpty { relation = relations.first?.id ?? "" } }
        .focusSoon($linkFocused)
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let c = jira?.client else { return }
            results = ((try? await c.pickIssues(query: query, excluding: key)) ?? []).filter { $0.key != key }
        }
    }

    private func step(_ by: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .ignored }
        let i = picked.flatMap(results.firstIndex) ?? -1
        picked = results[max(0, min(results.count - 1, i + by))]
        return .handled
    }

    /// "This issue blocks X": the link runs from this issue to X.
    private func link() {
        guard let r = relations.first(where: { $0.id == relation }), let p = picked else { return }
        onLink(r.type.name, r.outward ? key : p.key, r.outward ? p.key : key)
    }
}

struct LogWorkView: View {
    var onSubmit: (_ seconds: Int, _ comment: String, _ started: Date) -> Void
    @State private var duration = ""
    @State private var started = Date()
    @State private var comment = ""

    private var seconds: Int? { Self.parseDuration(duration) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Log Work").font(.headline)
            TextField("Time spent, e.g. 1h 30m", text: $duration).textFieldStyle(.roundedBorder).onSubmit(log)
            DatePicker("Started", selection: $started)
            TextField("Comment (optional)", text: $comment).textFieldStyle(.roundedBorder).onSubmit(log)
            HStack {
                if !duration.isEmpty, seconds == nil { Text("Use w, d, h, m").font(.caption).foregroundStyle(.red) }
                Spacer()
                Button("Log", action: log)
                    .glassButton(prominent: true).keyboardShortcut(.defaultAction).disabled(seconds == nil)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    /// Return in either field logs too: a field's own Return never reaches the default button.
    private func log() {
        if let s = seconds { onSubmit(s, comment, started) }
    }

    /// "1w 2d 3h 30m" → seconds (Jira's 8h day, 5d week). Bare numbers mean minutes.
    /// Seconds → "1d 7h", as Jira writes time: 8-hour days, 5-day weeks.
    nonisolated static func format(_ seconds: Int) -> String {
        var m = seconds / 60
        var parts: [String] = []
        for (unit, size) in [("w", 5 * 8 * 60), ("d", 8 * 60), ("h", 60), ("m", 1)] where m >= size {
            parts.append("\(m / size)\(unit)")
            m %= size
        }
        return parts.isEmpty ? "0m" : parts.joined(separator: " ")
    }

    nonisolated static func parseDuration(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return nil }
        if let n = Double(t) { return n > 0 ? Int(n * 60) : nil }
        var total = 0.0
        var matched = false
        for m in t.matches(of: /(\d+(?:\.\d+)?)\s*([wdhm])/) {
            matched = true
            let n = Double(m.1) ?? 0
            switch m.2 {
            case "w": total += n * 5 * 8 * 3600
            case "d": total += n * 8 * 3600
            case "h": total += n * 3600
            default: total += n * 60
            }
        }
        let leftovers = t.replacing(/(\d+(?:\.\d+)?)\s*[wdhm]/, with: "").trimmingCharacters(in: .whitespaces)
        return matched && leftovers.isEmpty && total > 0 ? Int(total) : nil
    }
}

/// Whether content has scrolled under the toolbar, for the preview column's band. A window does without: watched,
/// the scroll position ran through SwiftUI's graph on every frame of a scroll.
private struct ScrolledWatch: ViewModifier {
    let on: Bool
    @Binding var scrolled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if on {
            content.onScrollGeometryChange(for: Bool.self) {
                $0.contentOffset.y + $0.contentInsets.top > 1
            } action: {
                scrolled = $1
            }
        } else {
            content
        }
    }
}

/// A title leaving or arriving: a few points of travel, a little blur, and a fade.
private struct CrumbStep: ViewModifier {
    let dx: CGFloat
    let away: Bool
    func body(content: Content) -> some View {
        content.offset(x: away ? dx : 0).blur(radius: away ? 3 : 0).opacity(away ? 0 : 1)
    }
}

extension AnyTransition {
    fileprivate static func crumb(_ dx: CGFloat) -> AnyTransition {
        .modifier(active: CrumbStep(dx: dx, away: true), identity: CrumbStep(dx: dx, away: false))
    }
}

/// One person's work on an issue: their entries in the order Jira lists them, and the time they add up to.
struct WorklogGroup: Identifiable {
    let id: String
    let author: JiraUser?
    var logs: [Worklog]
    var seconds: Int { logs.reduce(0) { $0 + $1.timeSpentSeconds } }

    /// By author, in the order each first appears.
    static func make(_ logs: [Worklog]) -> [WorklogGroup] {
        var groups: [WorklogGroup] = []
        for w in logs {
            let id = w.author?.accountId ?? w.author?.displayName ?? "unknown"
            if let i = groups.firstIndex(where: { $0.id == id }) {
                groups[i].logs.append(w)
            } else {
                groups.append(WorklogGroup(id: id, author: w.author, logs: [w]))
            }
        }
        return groups
    }
}

extension IssueDetailView: @MainActor Equatable {
    /// By the issue alone. Its closures can't be compared, so without this every render of the window around it
    /// (three per step along the trail) rebuilt the whole page. The closures reach only `@State` and bindings, which
    /// an older copy still reads and writes live. `forward` and `back` change only with the target, but a pass
    /// before it: the window's own state updates first, its scene value a pass later.
    static func == (a: Self, b: Self) -> Bool { a.target == b.target && a.embedded == b.embedded }
}

/// Parent → key. A click on the parent opens it (⌘-click beside); a click on the key copies it. Not selectable
/// text: a double-click selected "CON" of "CON-7", and the parent is a link, not a quotation.
/// Built from one issue as a whole: the key, its parent and its icon change together. Read off a store that had
/// moved on, the new key showed beside the old issue's parent for as long as the new issue took to load.
private struct Crumb: View {
    let issue: Issue?
    /// Shown while there is no issue yet.
    let key: String
    let open: (String) -> Void
    /// The key was just copied; a tick shows beside it for a moment.
    @State private var copied = false

    var body: some View {
        let key = issue?.key ?? self.key
        HStack(spacing: 6) {
            if let p = issue?.fields.parent {
                Button {
                    open(p.key)
                } label: {
                    // The same gap as between the issue's own icon and key: a parent keeps its look when it becomes
                    // the title one step back.
                    HStack(spacing: 6) {
                        RemoteImage(url: p.fields.issuetype?.iconUrl).frame(width: 14, height: 14)
                        Text(p.key).monospaced()  // the key alone: the summary is in the tooltip and on the parent field
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "\(p.key) \(p.fields.summary)"))
                .help("\(p.fields.summary)\n\(String(localized: "Open \(p.key); ⌘-click for a new window"))")
                Image(systemName: "chevron.forward").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)  // a separator, not "Forward"
            }
            // Decorative: the Type field names the type, and in a toolbar the icon's label became the copy button's.
            RemoteImage(url: issue?.fields.issuetype.iconUrl, placeholder: "circle").frame(width: 14, height: 14)
                .accessibilityHidden(true)
            Button {
                copyToPasteboard(key)
                withAnimation(.easeOut(duration: 0.15)) { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    withAnimation(.easeOut(duration: 0.3)) { copied = false }
                }
            } label: {
                Text(key).monospaced().contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy \(key)")
            .help("Click to copy \(key)")
            // The tick hangs off the end so the key, and the toolbar around it, never shift.
            .overlay(alignment: .trailing) {
                if copied {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.green)
                        .offset(x: 18).transition(.opacity)
                        .accessibilityLabel("Copied")
                }
            }
        }
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize()  // two keys and two icons: never "CON…"
    }
}

/// A window's title: the crumb, with Back before it once there is somewhere to go back to. One item, so Back can
/// arrive and leave with the title's motion instead of shoving it sideways in a single frame. A view of its own
/// with its own state, so a step re-renders the title alone, not the page.
private struct WindowTitle: View {
    let issue: Issue?
    let key: String
    let back: (() -> Void)?
    let forward: Bool
    let open: (String) -> Void
    /// The issue the title shows: it follows `issue` only once the next issue's page is on screen.
    @State private var shown: Issue?
    /// Whether that title carries a Back: set with it, so Back comes and goes with the title it belongs to.
    @State private var hasBack = false

    var body: some View {
        // A step along the trail: the old title, with its Back, blurs out a few points towards where it went, then
        // the new one blurs in from the side it came from. Back belongs to the title it came with, so it arrives and
        // leaves with it, and nothing ever slides under anything: the toolbar resizes its item at once, which put a
        // sliding title under a fading Back.
        let title = shown ?? issue
        ZStack(alignment: .leading) {
            HStack(spacing: 10) {
                if hasBack { GlassBackButton { back?() } }
                Crumb(issue: title, key: key, open: open)
            }
            .id("\(title?.key ?? key)|\(hasBack)")
            .transition(
                .asymmetric(
                    insertion: .crumb(forward ? 10 : -10).animation(.smooth(duration: 0.22).delay(0.09)),
                    removal: .crumb(forward ? -10 : 10).animation(.easeIn(duration: 0.09))))
        }
        .frame(height: 36)  // Back's height either way, so nothing shifts up or down
        .padding(.trailing, 28)  // room for the "copied" tick, which hangs off the key's end
        .padding(.leading, 4)
        // One element holding the three: in a toolbar item, every child read out the first one's label, so the
        // key button was "QA-18 [QA] Parent" too.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: title?.key ?? key))
        .onChange(
            of: [issue?.key, issue?.fields.parent?.key, issue?.fields.issuetype.iconUrl?.absoluteString], initial: true
        ) {
            guard let issue else { return }
            let b = back != nil
            // A step to another issue. Started in the update that builds the next page, which blocks the main thread
            // on a long issue, the animation spent its time inside that frame and only its last few frames showed.
            // One turn later the page is on screen and the title moves in light frames.
            if let shown, shown.key != issue.key {
                Task {
                    self.shown = issue
                    hasBack = b
                }
            } else {
                shown = issue
                hasBack = b
            }
        }
    }
}

/// The window toolbar's Back, drawn inside the title item so it can move with the title: a glass circle.
private struct GlassBackButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.backward").font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 36).contentShape(.circle)
        }
        .buttonStyle(.plain)
        .modifier(GlassCircle())
        .help("Back to the previous issue (⌘[)")
        .keyboardShortcut("[", modifiers: .command)
        .accessibilityLabel("Back")
    }
}

private struct GlassCircle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content.background(.regularMaterial, in: .circle)
        }
    }
}

/// A small spinner that shows only once a wait has lasted: the full record of an issue usually lands within a
/// few frames, and a spinner that flashes for 40 ms reads as a glitch. Its space is kept, so nothing moves.
private struct DelayedSpinner: View {
    var size: ControlSize = .small
    @State private var shown = false
    var body: some View {
        ProgressView().controlSize(size).opacity(shown ? 1 : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(300))
                withAnimation(.easeOut(duration: 0.15)) { shown = true }
            }
    }
}
