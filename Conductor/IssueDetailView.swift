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

    func load(_ client: JiraClient, key: String) async {
        if issue == nil { issue = DiskCache.load(account: client.account, name: "issue-\(key)") }
        do {
            async let i = client.issue(key)
            async let t = client.transitions(key)
            async let m = client.editMeta(key)
            issue = try await i
            DiskCache.save(issue, account: client.account, name: "issue-\(key)")
            Spotlight.index([issue!], host: client.account.site.host() ?? "")
            transitions = (try? await t) ?? []
            editMeta = try? await m
        } catch {
            self.error = error.localizedDescription
            return
        }
        async let kids = client.search(jql: "parent = \"\(key)\" ORDER BY created ASC")
        async let types = client.linkTypes()
        children = ((try? await kids)?.issues ?? []).filter { !$0.fields.issuetype.isSubtask }
        linkTypes = (try? await types) ?? []
        await loadSprints(client)
    }

    private func loadSprints(_ client: JiraClient) async {
        guard canEdit(client.sprintField), let project = issue?.fields.project?.key else { return }
        guard let boards = try? await client.boards(project: project) else { return }
        var all: [Sprint] = []
        for b in boards where b.type == "scrum" { all += (try? await client.sprints(board: b.id)) ?? [] }
        var seen = Set<Int>()
        sprints = all.filter { seen.insert($0.id).inserted }
    }

    func perform(_ client: JiraClient, key: String, _ op: @Sendable (JiraClient) async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do { try await op(client) } catch { self.error = error.localizedDescription }
        await load(client, key: key)
    }
}

struct IssueDetailView: View {
    let key: String
    var open: (String) -> Void
    @Environment(Session.self) private var session
    @State private var store = IssueDetailStore()

    // Editing state
    @State private var summaryDraft: String?
    @State private var descriptionDraft: String?
    @State private var descriptionMentions: [String: String] = [:]
    @State private var commentDraft = ""
    @State private var commentMentions: [String: String] = [:]
    @State private var editingComment: Comment?
    @State private var editDraft = ""
    @State private var editMentions: [String: String] = [:]
    @State private var showAssign = false
    @State private var showLabels = false
    @State private var showLink = false
    @State private var showLogWork = false
    @State private var showCreateSubtask = false
    @State private var isDropTargeted = false
    @FocusState private var summaryFocused: Bool

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
        .task(id: key) { if let c = session.client { await store.load(c, key: key) } }
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
            CreateIssueView(defaultProject: store.issue?.fields.project, parentKey: key) { open($0) }
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
            #if DEBUG
            .task {
                guard ProcessInfo.processInfo.environment["CONDUCTOR_SCROLL"] == "comments" else { return }
                try? await Task.sleep(for: .seconds(1))
                proxy.scrollTo("comments", anchor: .top)
            }
            #endif
        }
        .environment(\.adfAttachments, issue.fields.attachment ?? [])
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
                Composer(text: draft, mentions: $descriptionMentions, placeholder: "Description", minHeight: 140, maxHeight: 420)
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
                if store.canEdit(session.client?.sprintField), !store.sprints.isEmpty {
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
                        Button { run { try await $0.watch(key, !w.isWatching) } } label: {
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
                            if let c = session.client { Task { await AttachmentOpener.open(a, client: c) } }
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
                    if w.author?.accountId == session.me?.accountId {
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
            if list.isEmpty { Text("No comments yet").foregroundStyle(.tertiary) }
            ForEach(list) { c in
                HStack(alignment: .top, spacing: 10) {
                    Avatar(user: c.author, size: 26)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(c.author?.displayName ?? "Unknown").font(.callout.weight(.semibold))
                            Text(c.created.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary).help(c.created.formatted())
                            if c.updated.timeIntervalSince(c.created) > 60 { Text("· edited").font(.caption).foregroundStyle(.tertiary) }
                            Spacer()
                            if c.author?.accountId == session.me?.accountId, editingComment == nil {
                                Menu {
                                    Button("Edit", systemImage: "pencil") { beginCommentEdit(c) }
                                    Button("Delete", systemImage: "trash", role: .destructive) { run { try await $0.deleteComment(key, id: c.id) } }
                                } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
                            }
                        }
                        if editingComment?.id == c.id {
                            Composer(text: $editDraft, mentions: $editMentions, placeholder: "Edit comment", showHint: false)
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
            HStack(alignment: .top, spacing: 10) {
                Avatar(user: session.me, size: 26).padding(.top, 8)
                Composer(text: $commentDraft, mentions: $commentMentions, placeholder: "Add a comment…  ⌘↩ to send", minHeight: 44)
                Button("Comment") { postComment() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isWorking || editingComment != nil)
                    .padding(.top, 6)
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some CustomizableToolbarContent {
        ToolbarItem(id: "refresh") {
            Button { if let c = session.client { Task { await store.load(c, key: key) } } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        ToolbarItem(id: "attach") {
            Button { attachFiles() } label: { Label("Attach Files", systemImage: "paperclip") }
                .help("Attach files (or drop them anywhere, or paste an image)")
        }
        ToolbarItem(id: "more") {
            Menu {
                Button("Create Subtask…", systemImage: "plus.square.on.square") { showCreateSubtask = true }
                Button("Link Issue…", systemImage: "link") { showLink = true }
                Button("Log Work…", systemImage: "clock") { showLogWork = true }
            } label: { Label("More", systemImage: "ellipsis.circle") }
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
        ToolbarItem(id: "copy") {
            Button {
                let url = session.client?.browseURL(key)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url?.absoluteString ?? key, forType: .string)
            } label: { Label("Copy Link", systemImage: "link") }
            .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        ToolbarItem(id: "browser") {
            Button {
                if let url = session.client?.browseURL(key) { NSWorkspace.shared.open(url) }
            } label: { Label("Open in Browser", systemImage: "safari") }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
    }

    // MARK: Actions

    private func run(_ op: @escaping @Sendable (JiraClient) async throws -> Void) {
        guard let c = session.client else { return }
        Task { await store.perform(c, key: key, op) }
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
        guard let field = session.client?.sprintField else { return }
        run { try await $0.editIssue(key, fields: [field: id.map { .number(Double($0)) } ?? .null]) }
    }

    private func postComment() {
        let text = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let doc = ADFNode.document(markdown: text, mentions: commentMentions)
        commentDraft = ""
        commentMentions = [:]
        run { try await $0.addComment(key, body: doc) }
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
        guard let c = session.client else { return }
        Task { if let url = await AttachmentOpener.download(a, client: c) { store.previewURL = url } }
    }

    private func saveAs(_ a: Attachment) {
        guard let c = session.client else { return }
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
        guard let image = (pb.readObjects(forClasses: [NSImage.self]) as? [NSImage])?.first,
              let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let name = "Pasted image \(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))) \(Date().formatted(date: .omitted, time: .shortened).replacingOccurrences(of: ":", with: ".")).png"
        run { try await $0.uploadAttachment(key, data: png, filename: name) }
    }
}

// MARK: - Pieces

struct AttachmentTile: View {
    let attachment: Attachment
    var onPreview: (URL) -> Void
    @Environment(Session.self) private var session
    @State private var busy = false

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
        .help("\(attachment.filename) — click to Quick Look")
    }

    private var icon: String {
        if attachment.mimeType.hasPrefix("image/") { return "photo" }
        if attachment.mimeType.hasPrefix("video/") { return "film" }
        if attachment.mimeType.contains("zip") { return "doc.zipper" }
        if attachment.mimeType.contains("pdf") { return "doc.richtext" }
        return "doc"
    }

    private func preview() {
        guard let client = session.client, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            if let url = await AttachmentOpener.download(attachment, client: client) { onPreview(url) }
        }
    }
}

enum AttachmentOpener {
    /// Downloads with auth into the app's temp folder; the same file is reused on later calls.
    static func download(_ attachment: Attachment, client: JiraClient) async -> URL? {
        let dir = FileManager.default.temporaryDirectory.appending(path: "attachments/\(attachment.id)", directoryHint: .isDirectory)
        let file = dir.appending(path: attachment.filename)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard let data = try? await client.data(for: attachment.content) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: file)
        return file
    }

    static func open(_ attachment: Attachment, client: JiraClient) async {
        if let file = await download(attachment, client: client) { NSWorkspace.shared.open(file) }
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
    @Environment(Session.self) private var session
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
            guard !Task.isCancelled, let c = session.client else { return }
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
