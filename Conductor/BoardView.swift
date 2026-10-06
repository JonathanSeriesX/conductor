import SwiftUI

@MainActor @Observable
final class BoardStore {
    var boards: [Board] = []
    var board: Board?
    var config: BoardConfiguration?
    var sprints: [Sprint] = []
    var sprint: Sprint?
    var issues: [Issue] = []
    var isLoading = false
    var error: String?
    var truncated = false

    var columns: [BoardConfiguration.Column] { config?.columnConfig.columns ?? [] }

    func issues(in column: BoardConfiguration.Column) -> [Issue] {
        let ids = Set(column.statuses.map(\.id))
        return issues.filter { ids.contains($0.fields.status.id) }
    }

    func load(_ client: JiraClient, project: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            boards = try await client.boards(project: project)
            if !boards.contains(where: { $0.id == board?.id }) { board = boards.first { $0.type == "scrum" } ?? boards.first }
            await loadBoard(client)
        } catch { self.error = error.localizedDescription }
    }

    func loadBoard(_ client: JiraClient) async {
        guard let board else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let cfg = client.boardConfiguration(board.id)
            async let sp = board.type == "scrum" ? client.sprints(board: board.id) : []
            config = try await cfg
            sprints = (try? await sp) ?? []
            if !sprints.contains(where: { $0.id == sprint?.id }) { sprint = sprints.first { $0.state == "active" } ?? sprints.first }
            await loadIssues(client)
        } catch { self.error = error.localizedDescription }
    }

    func loadIssues(_ client: JiraClient) async {
        guard let board else { return }
        var all: [Issue] = []
        var startAt = 0
        truncated = false
        repeat {
            guard let page = try? await client.boardIssues(board.id, sprint: sprint?.id, startAt: startAt) else { break }
            all += page.issues
            startAt += page.issues.count
            if page.issues.isEmpty { break }
            if startAt >= page.total { break }
            if startAt >= 300 { truncated = true; break } // ponytail: cap at 300 cards, page further if boards grow
        } while true
        issues = all
    }

    /// Moves a card by firing the first transition that lands in the column.
    func move(_ key: String, to column: BoardConfiguration.Column, client: JiraClient) async {
        let targets = Set(column.statuses.map(\.id))
        guard let issue = issues.first(where: { $0.key == key }), !targets.contains(issue.fields.status.id) else { return }
        do {
            let transitions = try await client.transitions(key)
            guard let t = transitions.first(where: { targets.contains($0.to.id) }) else {
                error = "No transition from \(issue.fields.status.name) to \(column.name) is allowed for \(key)."
                return
            }
            try await client.transition(key, to: t.id)
            await loadIssues(client)
        } catch { self.error = error.localizedDescription }
    }
}

struct BoardView: View {
    let target: BoardTarget
    @Environment(Session.self) private var session
    @State private var store = BoardStore()
    private var projectKey: String { target.projectKey }
    private var state: AccountState? { session.state(target.accountID) }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(store.columns) { column in
                    BoardColumn(column: column, issues: store.issues(in: column)) { key in
                        if let c = state?.client { Task { await store.move(key, to: column, client: c) } }
                    }
                    .environment(\.jira, state)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Backdrop())
        .overlay {
            if store.isLoading || state == nil, store.issues.isEmpty { ProgressView() }
            else if store.boards.isEmpty { ContentUnavailableView("No boards for \(projectKey)", systemImage: "rectangle.split.3x1") }
        }
        .navigationTitle(store.board?.name ?? projectKey)
        .navigationSubtitle(subtitle)
        .toolbar(id: "board") {
            ToolbarItem(id: "boardPicker") {
                // Setters, not onChange: only a user's pick reloads, not the store's own assignments.
                Picker("Board", selection: Binding(get: { store.board }, set: { b in
                    store.board = b
                    if let c = state?.client { Task { await store.loadBoard(c) } }
                })) {
                    ForEach(store.boards) { b in Text(b.name).tag(Optional(b)) }
                }
                .frame(maxWidth: 220)
                .disabled(store.boards.count < 2)
            }
            ToolbarItem(id: "sprintPicker") {
                if !store.sprints.isEmpty {
                    Picker("Sprint", selection: Binding(get: { store.sprint }, set: { sp in
                        store.sprint = sp
                        if let c = state?.client { Task { await store.loadIssues(c) } }
                    })) {
                        ForEach(store.sprints) { s in Text(s.name + (s.state == "active" ? " · active" : "")).tag(Optional(s)) }
                    }
                    .frame(maxWidth: 260)
                }
            }
            ToolbarItem(id: "refresh") {
                Button { if let c = state?.client { Task { await store.loadIssues(c) } } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
                    .help("Refresh (⌘R)")
            }
        }
        // Re-runs once sign-in completes after a restored launch.
        .task(id: "\(projectKey)|\(state?.id.uuidString ?? "")") {
            if let c = state?.client { await store.load(c, project: projectKey) }
        }
        .errorAlert($store.error)
        .frame(minWidth: 700, minHeight: 400)
    }

    private var subtitle: String {
        var s = "\(store.issues.count) issues"
        if store.truncated { s += " (first 300)" }
        if let sp = store.sprint { s = sp.name + " · " + s }
        return s
    }
}

struct BoardColumn: View {
    let column: BoardConfiguration.Column
    let issues: [Issue]
    var onDrop: (String) -> Void
    @Environment(Session.self) private var session
    @Environment(\.jira) private var jira
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(column.name).font(.headline)
                Text("\(issues.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary.opacity(0.6), in: .capsule)
                Spacer()
            }
            .padding(.horizontal, 4)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(issues) { issue in
                        BoardCard(issue: issue)
                            .draggable(issue.key)
                            .onTapGesture(count: 2) { open(issue.key) }
                            .contextMenu {
                                Button("Open in Conductor", systemImage: "arrow.up.forward.app") { open(issue.key) }
                                Button("Open in Browser", systemImage: "safari") {
                                    if let u = jira?.client.browseURL(issue.key) { NSWorkspace.shared.open(u) }
                                }
                            }
                    }
                }
                .padding(2)
            }
        }
        .padding(10)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor, lineWidth: targeted ? 2 : 0)
        }
        .dropDestination(for: String.self) { keys, _ in
            keys.forEach(onDrop)
            return true
        } isTargeted: { targeted = $0 }
        .animation(.easeOut(duration: 0.12), value: targeted)
    }

    private func open(_ key: String) {
        guard let jira else { return }
        session.pendingOpen = IssueTarget(accountID: jira.id, key: key)
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
    }
}

struct BoardCard: View {
    let issue: Issue
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(issue.fields.summary).font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                RemoteImage(url: issue.fields.issuetype.iconUrl, placeholder: "circle").frame(width: 14, height: 14)
                Text(issue.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                if let p = issue.fields.priority { PriorityIcon(priority: p, size: 12) }
                Avatar(user: issue.fields.assignee, size: 18)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.7), in: .rect(cornerRadius: 10))
        .contentShape(.rect)
    }
}
