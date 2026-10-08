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

    func load(_ state: AccountState, key: String, full: Bool = true) async {
        let client = state.client
        if issue == nil {
            // Last opened copy from disk, else what the list row already knows: either way, no blank page.
            // Everything the right column is built from comes with it, so no row appears or wakes up a second
            // later. The four files are read at once.
            let account = state.account
            async let diskIssue: Issue? = DiskCache.loadAsync(account: account, name: "issue-\(key)")
            async let diskMeta: EditMeta? = DiskCache.loadAsync(account: account, name: "editmeta-\(key)")
            async let diskTransitions: [Transition]? = DiskCache.loadAsync(account: account, name: "transitions-\(key)")
            async let diskChildren: [Issue]? =
                full ? DiskCache.loadAsync(account: account, name: "children-\(key)") : nil
            issue = await diskIssue ?? state.peek[key]
            if let m = await diskMeta {
                editMeta = m
            } else if let i = issue, let m = state.editMetaByWorkflow[AccountState.workflowKey(i)] {
                editMeta = m
            }
            if let t = await diskTransitions {
                transitions = t
            } else if let i = issue, let t = state.transitionsByWorkflow[AccountState.workflowKey(i)] {
                transitions = t
            }
            if let kids = await diskChildren { children = kids }
            if full, canEdit(client.sprintField), let project = issue?.fields.project?.key {
                sprints = await state.sprints(project: project)
            }
        }
        do {
            async let i = client.issue(key)
            async let t = client.transitions(key)
            async let m = client.editMeta(key)
            async let kids = full ? client.search(jql: "parent = \"\(key)\" ORDER BY created ASC") : nil
            async let types = full ? state.linkTypes() : nil
            issue = try await i
            DiskCache.saveAsync(issue, account: state.account, name: "issue-\(key)")
            Spotlight.index([issue!], host: state.host)
            if let fresh = try? await t {
                transitions = fresh
                DiskCache.saveAsync(fresh, account: state.account, name: "transitions-\(key)")
            }
            if let fresh = try? await m {
                editMeta = fresh
                DiskCache.saveAsync(fresh, account: state.account, name: "editmeta-\(key)")
            }
            if full {
                if let page = try? await kids {
                    children = page.issues.filter { !$0.fields.issuetype.isSubtask }
                    DiskCache.saveAsync(children, account: state.account, name: "children-\(key)")
                }
                if let list = await types { linkTypes = list }
                prefetchRelated(state)
            }
        } catch {
            if (error as? JiraError)?.status == 404 {
                gone = true
                issue = nil
                return
            }
            if !error.isOffline, !error.isCancelled { self.error = error.localizedDescription }
            return
        }
        if full, canEdit(client.sprintField), let project = issue?.fields.project?.key {
            sprints = await state.sprints(project: project)
        }
        if full, allLabels.isEmpty, canEdit("labels") { allLabels = (try? await client.labels()) ?? [] }
    }

    /// Full records for everything this page can open with a click: subtasks, children, the parent and linked
    /// issues. One batched request, skipping what is already on disk.
    private func prefetchRelated(_ state: AccountState) {
        guard let issue else { return }
        var keys =
            (issue.fields.subtasks ?? []).map(\.key) + children.map(\.key)
            + (issue.fields.issuelinks ?? []).compactMap { $0.other?.key }
        if let p = issue.fields.parent?.key { keys.append(p) }
        let missing = Set(keys).filter { state.prefetched[$0] == nil || state.peek[$0] == nil }
        guard !missing.isEmpty else { return }
        let client = state.client
        let jql = "issuekey in (" + missing.map { "\"\($0)\"" }.joined(separator: ",") + ")"
        Task { @MainActor in
            guard let page = try? await client.search(jql: jql, fields: client.detailFields) else { return }
            for i in page.issues {
                DiskCache.saveAsync(i, account: state.account, name: "issue-\(i.key)")
                state.peek[i.key] = i
                state.prefetched[i.key] = i.fields.updated
            }
            DiskCache.saveAsync(state.prefetched, account: state.account, name: "prefetched")
        }
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
        await load(state, key: key, full: false)
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
    @State private var descriptionCaret: CGPoint?
    /// When a link in the description was last clicked, so that click does not also start editing.
    @State private var linkOpened: Date?
    @State private var editOriginal = ""
    @State private var editingComment: Comment?
    @State private var editDraft = ""
    @State private var editMentions: [String: String] = [:]
    @State private var showAssign = false
    @State private var showLabels = false
    @State private var showLink = false
    @State private var showLogWork = false
    @State private var showCreateSubtask = false
    @State private var showDueDate = false
    @State private var showRemind = false
    @State private var showParent = false
    @State private var showWatchers = false
    @State private var isDropTargeted = false
    /// A destructive action waiting for the user's confirmation: what it is and what it does.
    @State private var pendingDelete: (title: String, verb: String, perform: () -> Void)?
    @FocusState private var summaryFocused: Bool
    @FocusState private var descriptionFocused: Bool
    @FocusState private var editCommentFocused: Bool
    @FocusState private var commentFocused: Bool
    @State private var commentRequest = 0

    var body: some View {
        Group {
            if let issue = store.issue {
                content(issue)
            } else if store.gone {
                ContentUnavailableView(
                    "\(key) no longer exists", systemImage: "trash",
                    description: Text("It was deleted or moved in Jira."))
            } else if store.error == nil {
                ProgressView()
            } else {
                ContentUnavailableView("Couldn't load \(key)", systemImage: "exclamationmark.triangle")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Backdrop())
        .navigationTitle(key)  // the Window menu and restoration; the toolbar draws its own
        .toolbar(removing: .title)
        .toolbar(id: "issue") { toolbar }
        .focusedSceneValue(\.issueActions, actions)
        .task(id: "\(key)|\(session.reloadTick)") { if let jira { await store.load(jira, key: key) } }
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
        .sheet(isPresented: $showCreateSubtask) {
            CreateIssueView(
                defaultProject: store.issue?.fields.project.flatMap { p in jira.map { (p, $0) } }, parentKey: key
            ) { open($0) }
        }
        .confirmationDialog(
            pendingDelete?.title ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(pendingDelete?.verb ?? String(localized: "Delete"), role: .destructive) {
                pendingDelete?.perform()
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This can't be undone.")
        }
    }

    /// Asks first, then runs the write. Jira has no undo for these.
    private func confirmDelete(
        _ title: String, verb: String = String(localized: "Delete"), _ perform: @escaping () -> Void
    ) { pendingDelete = (title, verb, perform) }

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
                            .overlay(alignment: .topTrailing) { working }
                            GlassCard(title: "Comments") { comments(issue) }.id("comments")
                            metadata { fields(issue) }
                        } else {
                            HStack(alignment: .top, spacing: 16) {
                                VStack(alignment: .leading, spacing: 16) {
                                    cards(issue)
                                    GlassCard(title: "Comments") { comments(issue) }.id("comments")
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
                                .overlay(alignment: .topTrailing) { working }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
                .padding(.top, embedded ? 10 : 20)  // the crumb sits on the line of the list's chips
            }
            // The toolbar has no background, so blur what scrolls under it instead of letting buttons sit on text.
            .softScrollEdge()
            .onChange(of: commentRequest) {
                withAnimation { proxy.scrollTo("comments", anchor: .bottom) }
            }
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
        descriptionCard(issue)
        if let atts = issue.fields.attachment, !atts.isEmpty {
            GlassCard(title: "Attachments") { attachments(atts) }
        }
        if let subs = issue.fields.subtasks, !subs.isEmpty {
            GlassCard(title: "Subtasks") { refs(subs) }
        }
        if !store.children.isEmpty {
            GlassCard(title: "Child Issues") { children(store.children) }
        }
        if let links = issue.fields.issuelinks, !links.isEmpty {
            GlassCard(title: "Linked Issues") { linksList(links) }
        }
        if let wl = issue.fields.worklog, !wl.worklogs.isEmpty {
            GlassCard(title: "Work Log") { worklogs(wl.worklogs) }
        }
    }

    /// Parent → key. The parent opens on a click (⌘-click beside); the text can be selected and copied, so the
    /// click rides a simultaneous gesture, as on the summary.
    private var crumb: some View {
        HStack(spacing: 6) {
            if let p = store.issue?.fields.parent {
                HStack(spacing: 4) {
                    RemoteImage(url: p.fields.issuetype?.iconUrl).frame(width: 14, height: 14)
                    Text(p.key).monospaced()
                    Text(p.fields.summary).lineLimit(1)
                }
                .contentShape(.rect)
                .simultaneousGesture(TapGesture().onEnded { open(p.key) })
                .help("Open \(p.key); ⌘-click for a new window")
                Image(systemName: "chevron.forward").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
            }
            RemoteImage(url: store.issue?.fields.issuetype.iconUrl, placeholder: "circle").frame(width: 14, height: 14)
                .accessibilityLabel(store.issue?.fields.issuetype.name ?? String(localized: "Issue type"))
            Text(key).monospaced()
        }
        .font(.callout).foregroundStyle(.secondary)
        .textSelection(.enabled)
    }

    private func header(_ issue: Issue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if embedded { crumb }  // a window carries it in its toolbar
            if summaryDraft != nil {
                TextField("Summary", text: Binding($summaryDraft, or: ""), axis: .vertical)
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($summaryFocused)
                    .onSubmit { saveSummary() }
                    .onExitCommand { summaryDraft = nil }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
                    .padding(.horizontal, -8)
                    .task { focusSoon($summaryFocused) }
                    .onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) {
                        placeCaret(in: $0.object as? NSTextView)
                    }
                Text("↩ to save · esc to cancel").font(.caption2).foregroundStyle(.tertiary)
            } else {
                // Selectable, and a click (not a drag) edits, as on the web. A simultaneous gesture, because
                // selectable text keeps plain taps for itself.
                Text(issue.fields.summary)
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .textSelection(.enabled)
                    .contentShape(.rect)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            guard store.canEdit("summary") else { return }
                            editClick = NSEvent.mouseLocation
                            caretPending = true
                            summaryDraft = issue.fields.summary
                        })
            }
        }
    }

    private func descriptionCard(_ issue: Issue) -> some View {
        GlassCard {
            Text("Description").font(.headline).foregroundStyle(.secondary)
            if descriptionDraft != nil {
                Composer(
                    text: Binding($descriptionDraft, or: ""), mentions: $descriptionMentions,
                    placeholder: "Description", minHeight: 140, maxHeight: 420, uploadImage: uploadPasted,
                    focus: $descriptionFocused, caret: descriptionCaret,
                    actions: AnyView(
                        HStack(spacing: 10) {
                            Button("Cancel") {
                                descriptionDraft = nil
                                descriptionCaret = nil
                            }.glassButton().keyboardShortcut(.cancelAction)
                            // ⌘↩ belongs to whichever editor has focus; the comment box has the same shortcut.
                            Button("Save") { saveDescription() }.glassButton(prominent: true)
                                .keyboardShortcut(
                                    descriptionFocused ? KeyboardShortcut(.return, modifiers: .command) : nil)
                        })
                )
                .task { focusSoon($descriptionFocused) }
                if issue.fields.description?.hasLossyNodes == true {
                    Label(
                        "This description has images, panels or other content the editor can't keep. Saving replaces them with the text shown here; Cancel leaves the description as it is.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption).foregroundStyle(.orange)
                }
            } else if let d = issue.fields.description, !(d.content ?? []).isEmpty {
                ADFView(node: d)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    // A link click runs through openURL first; the tap that follows must not open the editor.
                    .environment(
                        \.openURL,
                        OpenURLAction { url in
                            linkOpened = .now
                            return .systemAction(url)
                        }
                    )
                    .simultaneousGesture(
                        SpatialTapGesture().onEnded { tap in
                            guard store.canEdit("description") else { return }
                            let at = tap.location
                            Task {
                                try? await Task.sleep(for: .milliseconds(80))
                                if let t = linkOpened, t.timeIntervalSinceNow > -0.5 { return }
                                descriptionCaret = at
                                beginDescriptionEdit(issue)
                            }
                        })
            } else if store.isPartial {
                ProgressView().controlSize(.small)
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
                        Label("Add labels…", systemImage: "tag").foregroundStyle(.tertiary)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "tag").foregroundStyle(.tertiary)
                            Wrap { ForEach(labels, id: \.self) { Chip(text: $0) } }
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!store.canEdit("labels"))
                .popover(isPresented: $showLabels, arrowEdge: .bottom) {
                    LabelsEditor(labels: labels, suggestions: store.allLabels) { new in
                        showLabels = false
                        run { try await $0.editIssue(key, fields: ["labels": .array(new.map(JSONValue.string))]) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var working: some View {
        if store.isWorking { ProgressView().controlSize(.small).padding(12) }
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
        field("Status") {
            Menu {
                ForEach(store.transitions) { t in
                    Toggle(
                        isOn: Binding(
                            get: { t.to.id == issue.fields.status.id },
                            set: { on in
                                if on { run { try await $0.transition(key, to: t.id) } }
                            })
                    ) { Text(t.name) }
                }
            } label: {
                StatusPill(status: issue.fields.status)
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
            .disabled(store.transitions.isEmpty)
        }
    }

    @ViewBuilder private func priorityField(_ issue: Issue) -> some View {
        field("Priority") {
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
            } else {
                priorityLabel(issue.fields.priority)
            }
        }
    }

    @ViewBuilder private func assigneeField(_ issue: Issue) -> some View {
        field("Assignee") {
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
            .popover(isPresented: $showAssign, arrowEdge: .leading) {
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
                    .help("Open \(p.key); ⌘-click for a new window")
                    .contextMenu {
                        Button("Open", systemImage: "arrow.forward") {
                            open(IssueTarget(accountID: target.accountID, key: p.key))
                        }
                        Button("Open in New Window", systemImage: "macwindow.badge.plus") { openWindow(p.key) }
                        if store.canEdit("parent") {
                            Divider()
                            Button("Replace…", systemImage: "arrow.triangle.2.circlepath") { showParent = true }
                            Button("Remove", systemImage: "minus.circle", role: .destructive) {
                                run { try await $0.editIssue(key, fields: ["parent": .null]) }
                            }
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
                }
            }
            .popover(isPresented: $showParent, arrowEdge: .leading) {
                ParentPicker(
                    key: key, current: issue.fields.parent?.key,
                    jql:
                        "project = \"\(issue.fields.project?.key ?? "")\" AND hierarchyLevel = \((issue.fields.issuetype.hierarchyLevel ?? 0) + 1) ORDER BY updated DESC"
                ) { new in
                    showParent = false
                    run {
                        try await $0.editIssue(
                            key, fields: ["parent": new.map { .object(["key": .string($0)]) } ?? .null])
                    }
                }
            }
        }
        // Sprint, due date and points rows are there from the first frame: a site that has the field shows the
        // row, and the menu wakes up once the edit screen is known. Nothing moves when it arrives.
        if store.canEdit(jira?.client.sprintField), !store.sprints.isEmpty {
            field("Sprint") {
                Menu {
                    Button("No sprint") { setSprint(nil) }
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
            }
        } else if issue.points != nil || !(jira?.client.pointsFields.isEmpty ?? true) {
            field("Story Points") {
                Text(issue.points?.formatted() ?? String(localized: "None")).foregroundStyle(
                    issue.points == nil ? .secondary : .primary)
            }
        }
        multiValue("Components", field: "components", current: issue.fields.components ?? [])
        multiValue("Fix Versions", field: "fixVersions", current: issue.fields.fixVersions ?? [])
        if let tt = issue.fields.timetracking, tt.timeSpent != nil || tt.originalEstimate != nil {
            field("Time") {
                VStack(alignment: .leading, spacing: 2) {
                    if let s = tt.timeSpent { Text("\(s) logged") }
                    if let r = tt.remainingEstimate {
                        Text("\(r) remaining").foregroundStyle(.secondary)
                    } else if let o = tt.originalEstimate {
                        Text("\(o) estimated").foregroundStyle(.secondary)
                    }
                }
            }
        }
        if let w = issue.fields.watches {
            field("Watchers") {
                Button {
                    showWatchers = true
                } label: {
                    Label("\(w.watchCount) watching", systemImage: w.isWatching ? "eye.fill" : "eye")
                        .foregroundStyle(w.isWatching ? Color.accentColor : .primary)
                }
                .buttonStyle(.plain)
                .help("Who is watching; right-click to watch or stop")
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
            w.isWatching ? "Stop Watching This Issue" : "Watch This Issue",
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

    private func field<V: View>(_ name: LocalizedStringKey, @ViewBuilder _ value: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).textCase(.uppercase).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            value()
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
                        Button("Save As…", systemImage: "square.and.arrow.down") { saveAs(a) }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            confirmDelete(String(localized: "Delete “\(a.filename)”?")) {
                                run { try await $0.deleteAttachment(id: a.id) }
                            }
                        }
                    }
            }
        }
    }

    private func refs(_ refs: [IssueRef]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(refs) { r in
                Button {
                    open(r.key)
                } label: {
                    HStack(spacing: 8) {
                        RemoteImage(url: r.fields.issuetype?.iconUrl).frame(width: 14, height: 14)
                        Text(r.key).font(.callout.monospaced()).foregroundStyle(.secondary)
                        Text(r.fields.summary).lineLimit(1)
                        Spacer()
                        if let s = r.fields.status { StatusPill(status: s) }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func children(_ issues: [Issue]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(issues) { i in
                Button {
                    open(i.key)
                } label: {
                    HStack(spacing: 8) {
                        RemoteImage(url: i.fields.issuetype.iconUrl).frame(width: 14, height: 14)
                        Text(i.key).font(.callout.monospaced()).foregroundStyle(.secondary)
                        Text(i.fields.summary).lineLimit(1)
                        Spacer()
                        Avatar(user: i.fields.assignee, size: 16)
                        StatusPill(status: i.fields.status)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
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
                            Button {
                                open(o.key)
                            } label: {
                                HStack(spacing: 8) {
                                    RemoteImage(url: o.fields.issuetype?.iconUrl).frame(width: 14, height: 14)
                                    Text(o.key).font(.callout.monospaced()).foregroundStyle(.secondary)
                                    Text(o.fields.summary).lineLimit(1)
                                    Spacer()
                                    if let s = o.fields.status { StatusPill(status: s) }
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Remove Link", systemImage: "link.badge.minus", role: .destructive) {
                                    confirmDelete(
                                        String(localized: "Remove the link to \(o.key)?"),
                                        verb: String(localized: "Remove")
                                    ) { run { try await $0.deleteLink(id: link.id) } }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func worklogs(_ logs: [Worklog]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(logs) { w in
                HStack(alignment: .top, spacing: 10) {
                    Avatar(user: w.author, size: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(w.author?.displayName ?? String(localized: "Unknown")).font(.callout.weight(.semibold))
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
                        Button {
                            confirmDelete(String(localized: "Delete this work log?")) {
                                run { try await $0.deleteWorklog(key, id: w.id) }
                            }
                        } label: {
                            Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
                        }
                        .buttonStyle(.plain).foregroundStyle(.tertiary).help("Delete work log")
                    }
                }
            }
        }
    }

    private func comments(_ issue: Issue) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            let list = issue.fields.comment?.comments ?? []
            if store.isPartial {
                ProgressView().controlSize(.small)
            } else if list.isEmpty {
                Text("No comments yet").foregroundStyle(.tertiary)
            }
            ForEach(list) { c in
                HStack(alignment: .top, spacing: 10) {
                    Avatar(user: c.author, size: 26)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(c.author?.displayName ?? String(localized: "Unknown")).font(.callout.weight(.semibold))
                            Text(c.created.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(
                                .secondary
                            ).help(c.created.formatted())
                            if c.updated.timeIntervalSince(c.created) > 60 {
                                Text("· edited").font(.caption).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if c.author?.accountId == jira?.me?.accountId, editingComment == nil {
                                // Plain buttons, not a menu: editing your own comment is a one-click thing.
                                Button {
                                    beginCommentEdit(c)
                                } label: {
                                    Label("Edit", systemImage: "pencil").labelStyle(.iconOnly)
                                }
                                .buttonStyle(.plain).foregroundStyle(.tertiary).help("Edit comment")
                                Button {
                                    confirmDelete(String(localized: "Delete this comment?")) {
                                        run { try await $0.deleteComment(key, id: c.id) }
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
                                }
                                .buttonStyle(.plain).foregroundStyle(.tertiary).help("Delete comment")
                            }
                        }
                        if editingComment?.id == c.id {
                            Composer(
                                text: $editDraft, mentions: $editMentions, placeholder: "Edit comment",
                                uploadImage: uploadPasted, focus: $editCommentFocused,
                                actions: AnyView(
                                    HStack(spacing: 10) {
                                        Button("Cancel") { editingComment = nil }.glassButton()
                                            .keyboardShortcut(.cancelAction)
                                        Button("Save") { saveCommentEdit(c) }.glassButton(prominent: true)
                                            .keyboardShortcut(
                                                editCommentFocused
                                                    ? KeyboardShortcut(.return, modifiers: .command) : nil
                                            )
                                            .disabled(
                                                editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    })
                            )
                            .task { focusSoon($editCommentFocused) }
                        } else {
                            ADFView(node: c.body)
                        }
                    }
                }
            }
            Divider()
            CommentComposer(
                disabled: store.isWorking || editingComment != nil, focusRequest: commentRequest,
                uploadImage: uploadPasted, focus: $commentFocused
            ) { doc in
                await run { try await $0.addComment(key, body: doc) }.value
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some CustomizableToolbarContent {
        // A split view puts every column's .navigation items at the window's leading edge, over the list; the
        // preview column's belong above the preview.
        ToolbarItem(id: "back", placement: embedded ? .automatic : .navigation) {
            if let back {
                Button(action: back) { Label("Back", systemImage: "chevron.backward") }
                    .help("Back to the previous issue (⌘[)")
                    .keyboardShortcut("[", modifiers: .command)
            }
        }
        // The window's title is the crumb; the preview column draws it above the summary and keeps its actions
        // at the leading edge, with no spacer.
        if !embedded {
            ToolbarItem(id: "title", placement: .navigation) { crumb.padding(.leading, 4) }.glassTitle()
        }
        ToolbarItem(id: "refresh") {
            Button {
                perform(.refresh)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh (⌘⇧R)")
        }
        ToolbarItem(id: "attach") {
            Button {
                attachFiles()
            } label: {
                Label("Attach Files", systemImage: "paperclip")
            }
            .help("Attach files. You can also drop them anywhere or paste an image.")
            .disabled(store.issue == nil)
        }
        ToolbarItem(id: "more") {
            Menu {
                Button("Create Subtask…", systemImage: "plus.square.on.square") { showCreateSubtask = true }
                Button("Link Issue…", systemImage: "link") { showLink = true }
                Button("Log Work…", systemImage: "clock") { showLogWork = true }
                Button("Remind Me…", systemImage: "bell") { showRemind = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("Subtask, link, log work, reminder")
            .disabled(store.issue == nil)
            .popover(isPresented: $showRemind, arrowEdge: .bottom) {
                if let url = jira?.client.browseURL(key) {
                    ReminderView(url: url, key: key, summary: store.issue?.fields.summary ?? "") { showRemind = false }
                }
            }
            .popover(isPresented: $showLink, arrowEdge: .bottom) {
                LinkIssueView(key: key, types: store.linkTypes) { type, outward, inward in
                    showLink = false
                    run { try await $0.link(type: type, from: outward, to: inward) }
                }
            }
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
        // Shortcuts live on the Issue menu items, so the menu bar lists them.
        ToolbarItem(id: "copy") {
            Button {
                perform(.copyLink)
            } label: {
                Label("Copy Link", systemImage: "link")
            }
            .help("Copy link (⌘⇧C)")
            .disabled(store.issue == nil)
        }
        ToolbarItem(id: "browser") {
            Button {
                perform(.openInBrowser)
            } label: {
                Label("Open in Browser", systemImage: "safari")
            }
            .help("Open in browser (⌘⇧O)")
            .disabled(store.issue == nil)
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
            isEditing: summaryDraft != nil || descriptionDraft != nil || editingComment != nil,
            back: back,
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
        case .copyMarkdown: copyToPasteboard(jira.client.markdownLink(key, summary: summary))
        case .assign: showAssign = true
        case .assignToMe:
            let me = jira.me?.accountId
            run { try await $0.assign(key, to: me) }
        case .watch:
            let on = store.issue?.fields.watches?.isWatching != true
            let me = jira.me?.accountId
            run { try await $0.watch(key, on, me: me) }
        case .transition(let id): run { try await $0.transition(key, to: id) }
        case .remind: showRemind = true
        case .editSummary:
            caretPending = true
            summaryDraft = summary
        case .editDescription: if let issue = store.issue { beginDescriptionEdit(issue) }
        case .comment: commentRequest += 1
        case .attach: attachFiles()
        case .link: showLink = true
        case .logWork: showLogWork = true
        case .subtask: showCreateSubtask = true
        case .refresh: Task { await store.load(jira, key: key) }
        }
    }

    /// The task resolves to whether the write succeeded, so editors can keep a draft that failed to save.
    @discardableResult
    private func run(_ op: @escaping @Sendable (JiraClient) async throws -> Void) -> Task<Bool, Never> {
        guard let jira else { return Task { false } }
        return Task {
            let ok = await store.perform(jira, key: key, op)
            if ok { session.listTick += 1 }
            return ok
        }
    }

    /// Focus set in the same pass that creates the field is lost; one turn of the run loop later it sticks.
    private func focusSoon(_ focus: FocusState<Bool>.Binding) {
        DispatchQueue.main.async { focus.wrappedValue = true }
    }

    /// Puts the caret under the click that opened the editor, or at the end when a key opened it (⌘E).
    /// Focus selects everything; this runs inside that selection change, so no frame ever shows it.
    /// The editor sits where the text was, in the same font, so the character under the point is the one clicked.
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

    private func saveSummary() {
        guard let draft = summaryDraft?.trimmingCharacters(in: .whitespacesAndNewlines), !draft.isEmpty else { return }
        guard draft.count <= 255 else {
            store.error = String(localized: "A summary can be 255 characters at most; this one is \(draft.count).")
            return
        }
        summaryDraft = nil
        guard draft != store.issue?.fields.summary else { return }
        Task {
            if !(await run { try await $0.editIssue(key, fields: ["summary": .string(draft)]) }.value) {
                summaryDraft = draft
            }
        }
    }

    private func beginDescriptionEdit(_ issue: Issue) {
        var mentions: [String: String] = [:]
        descriptionDraft = issue.fields.description?.markdown(mentions: &mentions) ?? ""
        descriptionOriginal = descriptionDraft ?? ""
        descriptionMentions = mentions
    }

    private func saveDescription() {
        guard let draft = descriptionDraft else { return }
        descriptionDraft = nil
        descriptionCaret = nil
        guard draft != descriptionOriginal else { return }
        let doc = ADFNode.document(markdown: draft, mentions: descriptionMentions)
        guard let value = try? JSONValue(doc) else { return }
        Task {
            if !(await run { try await $0.editIssue(key, fields: ["description": value]) }.value) {
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
        editingComment = c
    }

    private func saveCommentEdit(_ c: Comment) {
        editingComment = nil
        guard editDraft != editOriginal else { return }
        let doc = ADFNode.document(markdown: editDraft, mentions: editMentions)
        Task { if !(await run { try await $0.updateComment(key, id: c.id, body: doc) }.value) { editingComment = c } }
    }

    private func preview(_ a: Attachment) {
        guard let c = jira?.client else { return }
        Task { if let url = await AttachmentOpener.download(a, client: c) { store.previewURL = url } }
    }

    private func saveAs(_ a: Attachment) {
        guard let c = jira?.client else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = a.filename
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        Task {
            if let data = try? await c.data(for: a.content) { try? data.write(to: dest) }
        }
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
                        Color.clear.overlay { RemoteImage(url: attachment.thumbnail) }.clipped()
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
    }

    private func post() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let doc = ADFNode.document(markdown: body, mentions: mentions)
        Task {
            if await send(doc) {
                text = ""
                mentions = [:]
            }
        }
    }
}

enum AttachmentOpener {
    /// Downloads with auth into the app's temp folder; the same file is reused on later calls.
    static func download(_ attachment: Attachment, client: JiraClient) async -> URL? {
        let dir = FileManager.default.temporaryDirectory.appending(
            path: "attachments/\(attachment.id)", directoryHint: .isDirectory)
        let file = dir.appending(path: attachment.filename)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        // An inline image already has its bytes in the image cache; reuse them instead of fetching again.
        var data = await DiskCache.imageData(for: attachment.content)
        if data == nil { data = try? await client.data(for: attachment.content) }
        guard let data else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: file)
        return file
    }

    static func open(_ attachment: Attachment, client: JiraClient) async {
        if let file = await download(attachment, client: client) { NSWorkspace.shared.open(file) }
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
            HStack {
                if hadDate { Button("Clear") { onSave(nil) }.glassButton() }
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
            TextField("Add label, ↩ to add", text: $draft).textFieldStyle(.roundedBorder).onSubmit(add).focused(
                $focused)
            ForEach(matches, id: \.self) { m in
                Button {
                    labels.append(m)
                    draft = ""
                } label: {
                    Text(m).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                }
                .buttonStyle(.plain).padding(.horizontal, 6).padding(.vertical, 3)
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
        .task { DispatchQueue.main.async { focused = true } }
    }

    private func add() {
        let l = draft.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
        guard !l.isEmpty else { return }
        if !labels.contains(l) { labels.append(l) }
        draft = ""
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
    let key: String
    let current: String?
    /// Scope of the search: the same project, one hierarchy level up.
    var jql: String
    var onSave: (String?) -> Void
    @Environment(\.jira) private var jira
    @State private var query = ""
    @State private var results: [IssuePickerResult.Item] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Parent").font(.headline)
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
                Button("Set") { if let r = results.first { onSave(r.key) } }.glassButton(prominent: true)
                    .disabled(results.isEmpty)
            }
        }
        .padding(12)
        .frame(width: 320)
        .task { DispatchQueue.main.async { focused = true } }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let c = jira?.client else { return }
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

    /// Every link type offers both directions, worded from this issue's side.
    private var relations: [(id: String, label: String, type: LinkType, outward: Bool)] {
        types.flatMap { t in [(t.id + ">", t.outward, t, true), (t.id + "<", t.inward, t, false)] }
            .filter { $0.1 != $0.2.inward || $0.3 }  // skip the duplicate when both wordings are identical
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
        .task { DispatchQueue.main.async { linkFocused = true } }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let c = jira?.client else { return }
            results = ((try? await c.pickIssues(query: query, excluding: key)) ?? []).filter { $0.key != key }
        }
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
            TextField("Time spent, e.g. 1h 30m", text: $duration).textFieldStyle(.roundedBorder)
            DatePicker("Started", selection: $started)
            TextField("Comment (optional)", text: $comment).textFieldStyle(.roundedBorder)
            HStack {
                if !duration.isEmpty, seconds == nil { Text("Use w, d, h, m").font(.caption).foregroundStyle(.red) }
                Spacer()
                Button("Log") { if let s = seconds { onSubmit(s, comment, started) } }
                    .glassButton(prominent: true).keyboardShortcut(.defaultAction).disabled(seconds == nil)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    /// "1w 2d 3h 30m" → seconds (Jira's 8h day, 5d week). Bare numbers mean minutes.
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

/// Leading "New Issue" button shared by the issue page and the empty detail pane.
struct NewIssueToolbarItem: CustomizableToolbarContent {
    @Environment(Session.self) private var session
    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "new") {
            Button {
                session.createIssueRequested = true
            } label: {
                Label("New Issue", systemImage: "square.and.pencil")
            }
            .help("New issue (⌘N)")
        }
    }
}
