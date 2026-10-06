import SwiftUI

@MainActor @Observable
final class IssueDetailStore {
    var issue: Issue?
    var transitions: [Transition] = []
    var error: String?
    var isWorking = false

    func load(_ client: JiraClient, key: String) async {
        do {
            async let i = client.issue(key)
            async let t = client.transitions(key)
            issue = try await i
            transitions = (try? await t) ?? []
        } catch { self.error = error.localizedDescription }
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
    @State private var draft = ""
    @State private var showAssign = false

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
        .toolbar { toolbar }
        .task(id: key) { if let c = session.client { await store.load(c, key: key) } }
        .errorAlert($store.error)
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
                            GlassCard(title: "Description") {
                                if let d = issue.fields.description, !(d.content ?? []).isEmpty {
                                    ADFView(node: d)
                                } else {
                                    Text("No description").foregroundStyle(.tertiary)
                                }
                            }
                            if let atts = issue.fields.attachment, !atts.isEmpty {
                                GlassCard(title: "Attachments") { attachments(atts) }
                            }
                            if let subs = issue.fields.subtasks, !subs.isEmpty {
                                GlassCard(title: "Subtasks") { refs(subs) }
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
            Text(issue.fields.summary)
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .textSelection(.enabled)
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
                    .popover(isPresented: $showAssign, arrowEdge: .leading) { assignPopover }
                }
                field("Reporter") {
                    HStack(spacing: 6) {
                        Avatar(user: issue.fields.reporter, size: 20)
                        Text(issue.fields.reporter?.displayName ?? "—")
                    }
                }
                if let p = issue.fields.priority {
                    field("Priority") {
                        HStack(spacing: 6) { RemoteImage(url: p.iconUrl).frame(width: 14, height: 14); Text(p.name) }
                    }
                }
                field("Type") { Text(issue.fields.issuetype.name) }
                if let s = issue.activeSprint { field("Sprint") { Text(s.name) } }
                if let labels = issue.fields.labels, !labels.isEmpty {
                    field("Labels") {
                        FlowLabels(labels: labels)
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

    private func field<V: View>(_ name: String, @ViewBuilder _ value: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            value()
        }
    }

    private func attachments(_ atts: [Attachment]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], alignment: .leading, spacing: 10) {
            ForEach(atts) { a in AttachmentTile(attachment: a) }
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
                        }
                        ADFView(node: c.body)
                    }
                }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                Avatar(user: session.me, size: 26)
                TextEditor(text: $draft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 44, maxHeight: 160)
                    .padding(6)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty { Text("Add a comment…  ⌘↩ to send").foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false) }
                    }
                Button("Comment") { postComment() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isWorking)
            }
        }
    }

    private var assignPopover: some View {
        AssignPopover(key: key, current: store.issue?.fields.assignee) { accountId in
            showAssign = false
            run { try await $0.assign(key, to: accountId) }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { if let c = session.client { Task { await store.load(c, key: key) } } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r")
        }
        ToolbarSpacer()
        ToolbarItemGroup {
            Button {
                let url = session.client?.browseURL(key)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url?.absoluteString ?? key, forType: .string)
            } label: { Label("Copy Link", systemImage: "link") }
            .keyboardShortcut("c", modifiers: [.command, .shift])
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

    private func postComment() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        run { try await $0.addComment(key, text: text) }
    }
}

// MARK: - Pieces

struct FlowLabels: View {
    let labels: [String]
    var body: some View {
        // ponytail: simple wrap via Text concatenation; swap for a Layout if labels get long
        Text(labels.map { " \($0) " }.joined(separator: "  "))
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct AttachmentTile: View {
    let attachment: Attachment
    @Environment(Session.self) private var session
    @State private var opening = false

    var body: some View {
        Button(action: openFile) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    if attachment.thumbnail != nil {
                        RemoteImage(url: attachment.thumbnail)
                    } else {
                        Image(systemName: icon).font(.title).foregroundStyle(.secondary)
                    }
                    if opening { ProgressView().controlSize(.small) }
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
        .help(attachment.filename)
    }

    private var icon: String {
        if attachment.mimeType.hasPrefix("image/") { return "photo" }
        if attachment.mimeType.hasPrefix("video/") { return "film" }
        if attachment.mimeType.contains("zip") { return "doc.zipper" }
        if attachment.mimeType.contains("pdf") { return "doc.richtext" }
        return "doc"
    }

    private func openFile() {
        guard let client = session.client, !opening else { return }
        opening = true
        Task { defer { opening = false }; await AttachmentOpener.open(attachment, client: client) }
    }
}

enum AttachmentOpener {
    /// Downloads with auth to a temp file, then hands it to the default app.
    static func open(_ attachment: Attachment, client: JiraClient) async {
        guard let data = try? await client.data(for: attachment.content) else { return }
        let dir = FileManager.default.temporaryDirectory.appending(path: "attachments/\(attachment.id)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: attachment.filename)
        try? data.write(to: file)
        NSWorkspace.shared.open(file)
    }
}

struct AssignPopover: View {
    let key: String
    let current: JiraUser?
    var onPick: (String?) -> Void
    @Environment(Session.self) private var session
    @State private var query = ""
    @State private var users: [JiraUser] = []

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search people", text: $query).textFieldStyle(.roundedBorder)
            List {
                if let me = session.me, me.accountId != current?.accountId {
                    Button { onPick(me.accountId) } label: { Label("Assign to me", systemImage: "person.fill.checkmark") }
                }
                if current != nil {
                    Button { onPick(nil) } label: { Label("Unassign", systemImage: "person.slash") }
                }
                ForEach(users) { u in
                    Button { onPick(u.accountId) } label: {
                        HStack { Avatar(user: u, size: 20); Text(u.displayName) }
                    }
                }
            }
            .buttonStyle(.plain)
            .listStyle(.plain)
        }
        .padding(10)
        .frame(width: 260, height: 300)
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let c = session.client else { return }
            users = (try? await c.assignableUsers(key, query: query)) ?? []
        }
    }
}
