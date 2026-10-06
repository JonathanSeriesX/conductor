import SwiftUI
import QuickLook
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

    var priorities: [Priority] {
        editMeta?.fields["priority"]?.allowedValues?.compactMap { v in
            guard let o = v.object, let id = o["id"]?.string, let name = o["name"]?.string else { return nil }
            return Priority(id: id, name: name, iconUrl: o["iconUrl"]?.string.flatMap(URL.init))
        } ?? []
    }

    func canEdit(_ field: String?) -> Bool { field.flatMap { editMeta?.fields[$0] } != nil }

    /// Values editmeta offers for components or fix versions; archived versions are left out.
    func options(_ field: String) -> [NamedRef] {
        editMeta?.fields[field]?.allowedValues?.compactMap { v in
            guard let o = v.object, o["archived"] != .bool(true), let id = o["id"]?.string, let name = o["name"]?.string else { return nil }
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
            issue = await DiskCache.loadAsync(account: state.account, name: "issue-\(key)") ?? state.peek[key]
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
            transitions = (try? await t) ?? []
            editMeta = try? await m
            if full {
                if let page = try? await kids { children = page.issues.filter { !$0.fields.issuetype.isSubtask } }
                if let list = await types { linkTypes = list }
            }
        } catch {
            self.error = error.localizedDescription
            return
        }
        if full, canEdit(client.sprintField), let project = issue?.fields.project?.key {
            sprints = await state.sprints(project: project)
        }
    }

    /// Runs a write, then refreshes only what a write can change: the issue, its transitions and editmeta.
    func perform(_ state: AccountState, key: String, _ op: @Sendable (JiraClient) async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do { try await op(state.client) } catch { self.error = error.localizedDescription }
        await load(state, key: key, full: false)
    }
}

struct IssueDetailView: View {
    let target: IssueTarget
    var open: (IssueTarget) -> Void
    @Environment(Session.self) private var session
    @Environment(\.jira) private var jira
    @Environment(\.openWindow) private var openWindow
    @State private var store = IssueDetailStore()
    private var key: String { target.key }
    /// Keys from subtasks, links and parents live in the same account as this issue.
    private func open(_ key: String) { open(IssueTarget(accountID: target.accountID, key: key)) }

    // Editing state
    @State private var summaryDraft: String?
    @State private var descriptionDraft: String?
    @State private var descriptionMentions: [String: String] = [:]
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
    @State private var isDropTargeted = false
    @FocusState private var summaryFocused: Bool
    @State private var commentRequest = 0

    var body: some View {
        Group {
            if let issue = store.issue {
                content(issue)
            } else if store.error == nil {
                ProgressView()
            } else {
                ContentUnavailableView("Couldn't load \(key)", systemImage: "exclamationmark.triangle")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Backdrop())
        .navigationTitle(key)
        .navigationSubtitle(store.issue?.fields.project?.name ?? "")
        .toolbar(id: "issue") { toolbar }
        .focusedSceneValue(\.issueActions, actions)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar) // let the backdrop run under the glass buttons
        .task(id: "\(key)|\(session.reloadTick)") { if let jira { await store.load(jira, key: key) } }
        .errorAlert($store.error)
        .quickLookPreview($store.previewURL)
        .dropDestination(for: URL.self) { urls, _ in upload(urls: urls); return true } isTargeted: { isDropTargeted = $0 }
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
            CreateIssueView(defaultProject: store.issue?.fields.project.flatMap { p in jira.map { (p, $0) } }, parentKey: key) { open($0) }
        }
    }

    // MARK: Layout

    private func content(_ issue: Issue) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(issue)
                    GlassEffectContainer(spacing: 16) {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 16) {
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
                                GlassCard(title: "Comments") { comments(issue) }.id("comments")
                            }
                            metadata(issue).frame(width: 250)
                        }
                    }
                }
                .padding(20)
            }
            // The toolbar has no background, so blur what scrolls under it instead of letting buttons sit on text.
            .scrollEdgeEffectStyle(.soft, for: .top)
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
        .environment(\.previewAttachment) { preview($0) }
    }

    private func header(_ issue: Issue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let parent = issue.fields.parent {
                    Button { open(parent.key) } label: {
                        HStack(spacing: 4) {
                            RemoteImage(url: parent.fields.issuetype?.iconUrl).frame(width: 14, height: 14)
                            Text(parent.key)
                        }
                    }
                    .buttonStyle(.link)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                RemoteImage(url: issue.fields.issuetype.iconUrl).frame(width: 16, height: 16)
                Text(issue.key).font(.body.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let draft = Binding($summaryDraft) {
                TextField("Summary", text: draft, axis: .vertical)
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($summaryFocused)
                    .onSubmit { saveSummary() }
                    .onExitCommand { summaryDraft = nil }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
                    .padding(.horizontal, -8)
                    .onAppear { summaryFocused = true }
                Text("↩ to save · esc to cancel").font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text(issue.fields.summary)
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .textSelection(.enabled)
                    .contentShape(.rect)
                    .onTapGesture(count: 2) { if store.canEdit("summary") { summaryDraft = issue.fields.summary } }
                    .help(store.canEdit("summary") ? "Double-click to edit" : "")
            }
        }
    }

    private func descriptionCard(_ issue: Issue) -> some View {
        GlassCard {
            HStack {
                Text("Description").font(.headline).foregroundStyle(.secondary)
                Spacer()
                if descriptionDraft == nil, store.canEdit("description") {
                    Button { beginDescriptionEdit(issue) } label: { Image(systemName: "pencil") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Edit description")
                }
            }
            if let draft = Binding($descriptionDraft) {
                Composer(text: draft, mentions: $descriptionMentions, placeholder: "Description", minHeight: 140, maxHeight: 420, uploadImage: uploadPasted)
                if issue.fields.description?.hasLossyNodes == true {
                    Label("This description has tables, images or panels that the editor can't keep. Saving replaces it with what you see here.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { descriptionDraft = nil }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                    Button("Save") { saveDescription() }.buttonStyle(.glassProminent).keyboardShortcut(.return, modifiers: .command)
                }
            } else if let d = issue.fields.description, !(d.content ?? []).isEmpty {
                ADFView(node: d)
            } else if store.isPartial {
                ProgressView().controlSize(.small)
            } else {
                Text("No description").foregroundStyle(.tertiary)
            }
        }
    }

    private func metadata(_ issue: Issue) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                field("Status") {
                    Menu {
                        ForEach(store.transitions) { t in
                            Button { run { try await $0.transition(key, to: t.id) } } label: {
                                Label(t.name, systemImage: t.to.statusCategory.key == "done" ? "checkmark.circle" : "circle")
                            }
                        }
                    } label: {
                        StatusPill(status: issue.fields.status)
                    }
                    .menuStyle(.button).buttonStyle(.plain).fixedSize()
                    .disabled(store.transitions.isEmpty)
                }
                field("Assignee") {
                    Button { showAssign = true } label: {
                        HStack(spacing: 6) {
                            Avatar(user: issue.fields.assignee, size: 20)
                            Text(issue.fields.assignee?.displayName ?? "Unassigned").foregroundStyle(issue.fields.assignee == nil ? .secondary : .primary)
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
                field("Reporter") {
                    HStack(spacing: 6) {
                        Avatar(user: issue.fields.reporter, size: 20)
                        Text(issue.fields.reporter?.displayName ?? "—")
                    }
                }
                field("Priority") {
                    if store.canEdit("priority"), !store.priorities.isEmpty {
                        Menu {
                            ForEach(store.priorities, id: \.id) { p in
                                Button(p.name) { run { try await $0.editIssue(key, fields: ["priority": .object(["id": .string(p.id)])]) } }
                            }
                        } label: {
                            priorityLabel(issue.fields.priority)
                        }
                        .menuStyle(.button).buttonStyle(.plain).fixedSize()
                    } else {
                        priorityLabel(issue.fields.priority)
                    }
                }
                field("Type") { Text(issue.fields.issuetype.name) }
                if store.canEdit(jira?.client.sprintField), !store.sprints.isEmpty {
                    field("Sprint") {
                        Menu {
                            Button("No sprint") { setSprint(nil) }
                            ForEach(store.sprints) { s in
                                Button { setSprint(s.id) } label: {
                                    if s.id == issue.activeSprint?.id { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
                                }
                            }
                        } label: {
                            Text(issue.activeSprint?.name ?? "None").foregroundStyle(issue.activeSprint == nil ? .secondary : .primary)
                        }
                        .menuStyle(.button).buttonStyle(.plain).fixedSize()
                    }
                } else if let s = issue.activeSprint {
                    field("Sprint") { Text(s.name) }
                }
                let due = issue.fields.duedate.flatMap(DueDate.parse)
                if due != nil || store.canEdit("duedate") {
                    field("Due") {
                        Button { showDueDate = true } label: {
                            let overdue = due.map { $0 < Calendar.current.startOfDay(for: .now) } == true && issue.fields.status.statusCategory.key != "done"
                            Text(due?.formatted(date: .abbreviated, time: .omitted) ?? "None")
                                .foregroundStyle(due == nil ? AnyShapeStyle(.secondary) : overdue ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                        }
                        .buttonStyle(.plain)
                        .disabled(!store.canEdit("duedate"))
                        .popover(isPresented: $showDueDate, arrowEdge: .leading) {
                            DueDatePicker(date: due) { new in
                                showDueDate = false
                                run { try await $0.editIssue(key, fields: ["duedate": new.map { .string(DueDate.string($0)) } ?? .null]) }
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
                            Text(issue.points?.formatted() ?? "None").foregroundStyle(issue.points == nil ? .secondary : .primary)
                        }
                        .menuStyle(.button).buttonStyle(.plain).fixedSize()
                    }
                } else if let points = issue.points {
                    field("Story Points") { Text(points.formatted()) }
                }
                multiValue("Components", field: "components", current: issue.fields.components ?? [])
                multiValue("Fix Versions", field: "fixVersions", current: issue.fields.fixVersions ?? [])
                field("Labels") {
                    Button { showLabels = true } label: {
                        if let labels = issue.fields.labels, !labels.isEmpty {
                            Wrap { ForEach(labels, id: \.self) { Chip(text: $0) } }
                        } else {
                            Text("None").foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.canEdit("labels"))
                    .popover(isPresented: $showLabels, arrowEdge: .leading) {
                        LabelsEditor(labels: issue.fields.labels ?? []) { new in
                            showLabels = false
                            run { try await $0.editIssue(key, fields: ["labels": .array(new.map(JSONValue.string))]) }
                        }
                    }
                }
                if let tt = issue.fields.timetracking, tt.timeSpent != nil || tt.originalEstimate != nil {
                    field("Time") {
                        VStack(alignment: .leading, spacing: 2) {
                            if let s = tt.timeSpent { Text("\(s) logged") }
                            if let r = tt.remainingEstimate { Text("\(r) remaining").foregroundStyle(.secondary) }
                            else if let o = tt.originalEstimate { Text("\(o) estimated").foregroundStyle(.secondary) }
                        }
                    }
                }
                if let w = issue.fields.watches {
                    field("Watchers") {
                        Button { let me = jira?.me?.accountId; run { try await $0.watch(key, !w.isWatching, me: me) } } label: {
                            Label("\(w.watchCount) watching", systemImage: w.isWatching ? "eye.fill" : "eye")
                                .foregroundStyle(w.isWatching ? Color.accentColor : .primary)
                        }
                        .buttonStyle(.plain)
                        .help(w.isWatching ? "Stop watching" : "Watch this issue")
                    }
                }
                if let c = issue.fields.created { field("Created") { Text(c.formatted(date: .abbreviated, time: .shortened)) } }
                if let u = issue.fields.updated { field("Updated") { Text(u.formatted(.relative(presentation: .named))).help(u.formatted()) } }
            }
            .font(.callout)
        }
        .overlay(alignment: .topTrailing) {
            if store.isWorking { ProgressView().controlSize(.small).padding(12) }
        }
    }

    /// Components and fix versions: a menu of checkable values when editable, else just the names.
    @ViewBuilder
    private func multiValue(_ name: String, field id: String, current: [NamedRef]) -> some View {
        let options = store.options(id)
        let selected = Set(current.map(\.id))
        let label = Text(current.isEmpty ? "None" : current.map(\.name).joined(separator: ", "))
            .foregroundStyle(current.isEmpty ? .secondary : .primary)
        if !options.isEmpty {
            field(name) {
                Menu {
                    ForEach(options) { o in
                        Toggle(o.name, isOn: Binding(get: { selected.contains(o.id) }, set: { on in
                            let ids = on ? selected.union([o.id]) : selected.subtracting([o.id])
                            run { try await $0.editIssue(key, fields: [id: .array(ids.sorted().map { .object(["id": .string($0)]) })]) }
                        }))
                    }
                } label: { label }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
            }
        } else if !current.isEmpty {
            field(name) { label }
        }
    }

    private func priorityLabel(_ p: Priority?) -> some View {
        HStack(spacing: 6) {
            if let p { PriorityIcon(priority: p); Text(p.name) } else { Text("None").foregroundStyle(.secondary) }
        }
    }

    private func field<V: View>(_ name: String, @ViewBuilder _ value: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
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
                        Button("Delete", systemImage: "trash", role: .destructive) { run { try await $0.deleteAttachment(id: a.id) } }
                    }
            }
        }
    }

    private func refs(_ refs: [IssueRef]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(refs) { r in
                Button { open(r.key) } label: {
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
                Button { open(i.key) } label: {
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
                            Button { open(o.key) } label: {
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
                                Button("Remove Link", systemImage: "link.badge.minus", role: .destructive) { run { try await $0.deleteLink(id: link.id) } }
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
                            Text(w.author?.displayName ?? "Unknown").font(.callout.weight(.semibold))
                            Text("logged \(w.timeSpent)").font(.callout)
                            Text(w.started.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                        }
                        if let c = w.comment, !c.plainText.isEmpty { Text(c.plainText).font(.callout).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if w.author?.accountId == jira?.me?.accountId {
                        Button { run { try await $0.deleteWorklog(key, id: w.id) } } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(.tertiary).help("Delete work log")
                    }
                }
            }
        }
    }

    private func comments(_ issue: Issue) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            let list = issue.fields.comment?.comments ?? []
            if store.isPartial { ProgressView().controlSize(.small) }
            else if list.isEmpty { Text("No comments yet").foregroundStyle(.tertiary) }
            ForEach(list) { c in
                HStack(alignment: .top, spacing: 10) {
                    Avatar(user: c.author, size: 26)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(c.author?.displayName ?? "Unknown").font(.callout.weight(.semibold))
                            Text(c.created.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary).help(c.created.formatted())
                            if c.updated.timeIntervalSince(c.created) > 60 { Text("· edited").font(.caption).foregroundStyle(.tertiary) }
                            Spacer()
                            if c.author?.accountId == jira?.me?.accountId, editingComment == nil {
                                Menu {
                                    Button("Edit", systemImage: "pencil") { beginCommentEdit(c) }
                                    Button("Delete", systemImage: "trash", role: .destructive) { run { try await $0.deleteComment(key, id: c.id) } }
                                } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
                            }
                        }
                        if editingComment?.id == c.id {
                            Composer(text: $editDraft, mentions: $editMentions, placeholder: "Edit comment", uploadImage: uploadPasted)
                            HStack {
                                Spacer()
                                Button("Cancel") { editingComment = nil }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                                Button("Save") { saveCommentEdit(c) }.buttonStyle(.glassProminent).keyboardShortcut(.return, modifiers: .command)
                                    .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        } else {
                            ADFView(node: c.body)
                        }
                    }
                }
            }
            Divider()
            CommentComposer(disabled: store.isWorking || editingComment != nil, focusRequest: commentRequest, uploadImage: uploadPasted) { doc in
                run { try await $0.addComment(key, body: doc) }
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some CustomizableToolbarContent {
        NewIssueToolbarItem()
        ToolbarSpacer(.flexible)
        ToolbarItem(id: "refresh") {
            Button { perform(.refresh) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Refresh (⌘⇧R)")
        }
        ToolbarItem(id: "attach") {
            Button { attachFiles() } label: { Label("Attach Files", systemImage: "paperclip") }
                .help("Attach files. You can also drop them anywhere or paste an image.")
        }
        ToolbarItem(id: "more") {
            Menu {
                Button("Create Subtask…", systemImage: "plus.square.on.square") { showCreateSubtask = true }
                Button("Link Issue…", systemImage: "link") { showLink = true }
                Button("Log Work…", systemImage: "clock") { showLogWork = true }
                Button("Remind Me…", systemImage: "bell") { showRemind = true }
            } label: { Label("More", systemImage: "ellipsis.circle") }
            .help("Subtask, link, log work, reminder")
            .popover(isPresented: $showRemind, arrowEdge: .bottom) {
                if let url = jira?.client.browseURL(key) {
                    ReminderView(url: url, key: key, summary: store.issue?.fields.summary ?? "") { showRemind = false }
                }
            }
            .popover(isPresented: $showLink, arrowEdge: .bottom) {
                LinkIssueView(key: key, types: store.linkTypes) { type, outward, inward in
                    showLink = false
                    run { try await $0.link(type: type, outward: outward, inward: inward) }
                }
            }
            .popover(isPresented: $showLogWork, arrowEdge: .bottom) {
                LogWorkView { seconds, comment, started in
                    showLogWork = false
                    run { try await $0.addWorklog(key, seconds: seconds, comment: comment.isEmpty ? nil : .document(markdown: comment), started: started) }
                }
            }
        }
        // Shortcuts live on the Issue menu items, so the menu bar lists them.
        ToolbarItem(id: "star") {
            let starred = session.isStarred(target)
            Button { perform(.star) } label: { Label(starred ? "Unstar" : "Star", systemImage: starred ? "star.fill" : "star") }
                .help(starred ? "Unstar (⌘D)" : "Star: keep it in the sidebar (⌘D)")
        }
        ToolbarItem(id: "copy") {
            Button { perform(.copyLink) } label: { Label("Copy Link", systemImage: "link") }
                .help("Copy link (⌘⇧C)")
        }
        ToolbarItem(id: "browser") {
            Button { perform(.openInBrowser) } label: { Label("Open in Browser", systemImage: "safari") }
                .help("Open in browser (⌘⇧O)")
        }
        ToolbarSpacer(.flexible)
    }

    // MARK: Actions

    private var actions: IssueActions? {
        guard let issue = store.issue else { return nil }
        return IssueActions(
            key: key,
            watching: issue.fields.watches?.isWatching == true,
            starred: session.isStarred(target),
            assignedToMe: issue.fields.assignee?.accountId != nil && issue.fields.assignee?.accountId == jira?.me?.accountId,
            transitions: store.transitions,
            canEditSummary: store.canEdit("summary"),
            canEditDescription: store.canEdit("description"),
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
        case .assignToMe: let me = jira.me?.accountId; run { try await $0.assign(key, to: me) }
        case .watch:
            let on = store.issue?.fields.watches?.isWatching != true, me = jira.me?.accountId
            run { try await $0.watch(key, on, me: me) }
        case .transition(let id): run { try await $0.transition(key, to: id) }
        case .star: session.toggleStar(target, summary: summary)
        case .remind: showRemind = true
        case .editSummary: summaryDraft = summary
        case .editDescription: if let issue = store.issue { beginDescriptionEdit(issue) }
        case .comment: commentRequest += 1
        case .attach: attachFiles()
        case .link: showLink = true
        case .logWork: showLogWork = true
        case .subtask: showCreateSubtask = true
        case .refresh: Task { await store.load(jira, key: key) }
        }
    }

    private func run(_ op: @escaping @Sendable (JiraClient) async throws -> Void) {
        guard let jira else { return }
        Task { await store.perform(jira, key: key, op) }
    }

    private func saveSummary() {
        guard let draft = summaryDraft?.trimmingCharacters(in: .whitespacesAndNewlines), !draft.isEmpty else { return }
        summaryDraft = nil
        guard draft != store.issue?.fields.summary else { return }
        run { try await $0.editIssue(key, fields: ["summary": .string(draft)]) }
    }

    private func beginDescriptionEdit(_ issue: Issue) {
        var mentions: [String: String] = [:]
        descriptionDraft = issue.fields.description?.markdown(mentions: &mentions) ?? ""
        descriptionMentions = mentions
    }

    private func saveDescription() {
        guard let draft = descriptionDraft else { return }
        let doc = ADFNode.document(markdown: draft, mentions: descriptionMentions)
        descriptionDraft = nil
        guard let value = try? JSONValue(doc) else { return }
        run { try await $0.editIssue(key, fields: ["description": value]) }
    }

    private func setSprint(_ id: Int?) {
        guard let field = jira?.client.sprintField else { return }
        run { try await $0.editIssue(key, fields: [field: id.map { .number(Double($0)) } ?? .null]) }
    }

    private func beginCommentEdit(_ c: Comment) {
        var mentions: [String: String] = [:]
        editDraft = c.body.markdown(mentions: &mentions)
        editMentions = mentions
        editingComment = c
    }

    private func saveCommentEdit(_ c: Comment) {
        let doc = ADFNode.document(markdown: editDraft, mentions: editMentions)
        editingComment = nil
        run { try await $0.updateComment(key, id: c.id, body: doc) }
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
                        RemoteImage(url: attachment.thumbnail)
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
        if attachment.mimeType.hasPrefix("image/") { return "photo" }
        if attachment.mimeType.hasPrefix("video/") { return "film" }
        if attachment.mimeType.contains("zip") { return "doc.zipper" }
        if attachment.mimeType.contains("pdf") { return "doc.richtext" }
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
    let send: (ADFNode) -> Void
    @State private var text = ""
    @State private var mentions: [String: String] = [:]
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Composer(text: $text, mentions: $mentions, placeholder: "Add a comment…  ⌘↩ to send", minHeight: 44, uploadImage: uploadImage, focus: $focused)
            Button("Comment") { post() }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || disabled)
                .padding(.top, 6)
        }
        .onChange(of: focusRequest) { focused = true }
    }

    private func post() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        send(ADFNode.document(markdown: body, mentions: mentions))
        text = ""
        mentions = [:]
    }
}

enum AttachmentOpener {
    /// Downloads with auth into the app's temp folder; the same file is reused on later calls.
    static func download(_ attachment: Attachment, client: JiraClient) async -> URL? {
        let dir = FileManager.default.temporaryDirectory.appending(path: "attachments/\(attachment.id)", directoryHint: .isDirectory)
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
        let tomorrow9 = cal.date(bySettingHour: 9, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: .now)!)!
        let monday9 = cal.nextDate(after: .now, matching: DateComponents(hour: 9, minute: 0, weekday: 2), matchingPolicy: .nextTime)!
        return [("In 1 Hour", .now.addingTimeInterval(3600)), ("Tomorrow at 9:00", tomorrow9), ("Next Monday at 9:00", monday9)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Remind Me").font(.headline)
            if let existing {
                HStack {
                    Label(existing.formatted(date: .abbreviated, time: .shortened), systemImage: "bell.fill").font(.callout)
                    Spacer()
                    Button("Remove") { Notifier.cancelReminder(for: url); done() }
                }
            }
            ForEach(presets, id: \.0) { title, at in
                Button(title) { set(at) }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
            Divider()
            HStack {
                DatePicker("At", selection: $date, in: Date.now..., displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                Button("Set") { set(date) }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(12)
        .frame(width: 280)
        .task { existing = await Notifier.reminder(for: url) }
    }

    private func set(_ at: Date) {
        Task {
            do { try await Notifier.remind(url, key: key, summary: summary, at: at); done() }
            catch { self.error = error.localizedDescription }
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
                if hadDate { Button("Clear") { onSave(nil) }.buttonStyle(.glass) }
                Spacer()
                Button("Save") { onSave(date) }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }
}

struct LabelsEditor: View {
    @State var labels: [String]
    var onSave: ([String]) -> Void
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Labels").font(.headline)
            if labels.isEmpty { Text("No labels").foregroundStyle(.tertiary).font(.callout) }
            Wrap { ForEach(labels, id: \.self) { l in Chip(text: l) { labels.removeAll { $0 == l } } } }
            TextField("Add label, ↩ to add", text: $draft).textFieldStyle(.roundedBorder).onSubmit(add)
            HStack { Spacer(); Button("Save") { add(); onSave(labels) }.buttonStyle(.glassProminent).keyboardShortcut(.return, modifiers: .command) }
        }
        .padding(12)
        .frame(width: 280)
    }

    private func add() {
        let l = draft.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
        guard !l.isEmpty else { return }
        if !labels.contains(l) { labels.append(l) }
        draft = ""
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

    /// Every link type offers both directions, worded from this issue's side.
    private var relations: [(id: String, label: String, type: LinkType, outward: Bool)] {
        types.flatMap { t in [(t.id + ">", t.outward, t, true), (t.id + "<", t.inward, t, false)] }
            .filter { $0.1 != $0.2.inward || $0.3 } // skip the duplicate when both wordings are identical
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Link \(key)").font(.headline)
            Picker("This issue", selection: $relation) {
                ForEach(relations, id: \.id) { Text($0.label).tag($0.id) }
            }
            TextField("Search issues by key or text", text: $query).textFieldStyle(.roundedBorder)
            List(selection: $picked) {
                ForEach(results) { r in
                    HStack(spacing: 8) {
                        Text(r.key).font(.callout.monospaced()).foregroundStyle(.secondary)
                        Text(r.summaryText ?? "").lineLimit(1)
                    }
                    .tag(r)
                }
            }
            .listStyle(.plain)
            .frame(height: 180)
            HStack {
                Spacer()
                Button("Link") {
                    guard let r = relations.first(where: { $0.id == relation }), let p = picked else { return }
                    onLink(r.type.name, r.outward ? key : p.key, r.outward ? p.key : key)
                }
                .buttonStyle(.glassProminent)
                .disabled(picked == nil || relation.isEmpty)
            }
        }
        .padding(12)
        .frame(width: 360)
        .onAppear { if relation.isEmpty { relation = relations.first?.id ?? "" } }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let c = jira?.client else { return }
            results = ((try? await c.pickIssues(query: query, excluding: key)) ?? []).filter { $0.key != key }
        }
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
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(seconds == nil)
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
            Button { session.createIssueRequested = true } label: { Label("New Issue", systemImage: "square.and.pencil") }
                .help("New issue (⌘N)")
        }
    }
}
