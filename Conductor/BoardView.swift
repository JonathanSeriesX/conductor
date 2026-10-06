import SwiftUI

@MainActor @Observable
final class BoardStore {
    var boards: [Board] = []
    var board: Board?
    var config: BoardConfiguration?
    var sprints: [Sprint] = []
    var sprint: Sprint?
    var quickFilters: [QuickFilter] = []
    var activeFilters: Set<Int> = []
    var issues: [Issue] = []
    var isLoading = false
    var error: String?
    var truncated = false
    private var generation = 0

    var columns: [BoardConfiguration.Column] { config?.columnConfig.columns ?? [] }

    func issues(in column: BoardConfiguration.Column, from list: [Issue]? = nil) -> [Issue] {
        let ids = Set(column.statuses.map(\.id))
        return (list ?? issues).filter { ids.contains($0.fields.status.id) }
    }

    func load(_ client: JiraClient, project: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            boards = try await client.boards(project: project)
            if !boards.contains(where: { $0.id == board?.id }) { board = boards.first { $0.type == "scrum" } ?? boards.first }
            await loadBoard(client)
        } catch { if !error.isOffline { self.error = error.localizedDescription } }
    }

    func loadBoard(_ client: JiraClient) async {
        guard let board else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let cfg = client.boardConfiguration(board.id)
            async let sp = board.type == "scrum" ? client.sprints(board: board.id) : []
            async let qf = client.quickFilters(board: board.id)
            config = try await cfg
            sprints = (try? await sp) ?? []
            quickFilters = (try? await qf) ?? []
            activeFilters = activeFilters.filter { id in quickFilters.contains { $0.id == id } }
            if !sprints.contains(where: { $0.id == sprint?.id }) { sprint = sprints.first { $0.state == "active" } ?? sprints.first }
            await loadIssues(client)
        } catch { if !error.isOffline { self.error = error.localizedDescription } }
    }

    /// Pages through the whole board, showing cards as each page lands.
    func loadIssues(_ client: JiraClient) async {
        guard let board else { return }
        generation += 1
        let gen = generation
        let jql = quickFilters.filter { activeFilters.contains($0.id) }.map { "(\($0.jql))" }.joined(separator: " AND ")
        var all: [Issue] = []
        truncated = false
        while true {
            guard let page = try? await client.boardIssues(board.id, sprint: sprint?.id, jql: jql.isEmpty ? nil : jql, startAt: all.count),
                  gen == generation else { break }
            all += page.issues
            issues = all
            if page.issues.isEmpty || all.count >= page.total { break }
            if all.count >= 2000 { truncated = true; break } // ponytail: 20 pages; past that a board wants server-side filtering
        }
        if gen == generation { issues = all }
    }

    func toggle(_ filter: QuickFilter, client: JiraClient) async {
        if activeFilters.contains(filter.id) { activeFilters.remove(filter.id) } else { activeFilters.insert(filter.id) }
        await loadIssues(client)
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

enum Swimlanes: String, CaseIterable {
    case none = "No Swimlanes", assignee = "Assignee", parent = "Parent"

    struct Lane: Identifiable { let id: String; let title: String; let issues: [Issue] }

    /// Lanes in first-seen order, with the "nobody" lane last.
    func lanes(_ issues: [Issue]) -> [Lane] {
        let key: (Issue) -> (String, String)? = switch self {
        case .none: { _ in ("all", "") }
        case .assignee: { $0.fields.assignee.map { ($0.accountId, $0.displayName) } }
        case .parent: { $0.fields.parent.map { ($0.key, "\($0.key)  \($0.fields.summary)") } }
        }
        var order: [String] = [], titles: [String: String] = [:], groups: [String: [Issue]] = [:], rest: [Issue] = []
        for i in issues {
            guard let (id, title) = key(i) else { rest.append(i); continue }
            if groups[id] == nil { order.append(id); titles[id] = title }
            groups[id, default: []].append(i)
        }
        var lanes = order.map { Lane(id: $0, title: titles[$0]!, issues: groups[$0]!) }
        if !rest.isEmpty { lanes.append(Lane(id: "none", title: self == .assignee ? "Unassigned" : "No parent", issues: rest)) }
        return lanes
    }
}

struct BoardView: View {
    let target: BoardTarget
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var store = BoardStore()
    @AppStorage("boardSwimlanes") private var swimlanes = Swimlanes.none
    private var projectKey: String { target.projectKey }
    private var state: AccountState? { session.state(target.accountID) }

    var body: some View {
        ScrollView(swimlanes == .none ? .horizontal : [.horizontal, .vertical]) {
            if swimlanes == .none {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(store.columns) { column in
                        BoardColumn(column: column, issues: store.issues(in: column), onDrop: drop(column))
                    }
                }
                .padding(16)
            } else {
                lanes
            }
        }
        .environment(\.jira, state)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Backdrop())
        .safeAreaInset(edge: .top, spacing: 0) { quickFilterBar }
        .overlay {
            if state == nil, !session.isRestoring {
                // A restored window whose account signed out, or one from a dev launch with a fresh account id.
                ContentUnavailableView {
                    Label("\(projectKey) isn't available", systemImage: "person.crop.circle.badge.xmark")
                } description: {
                    Text("The account this board belongs to is no longer signed in.")
                } actions: {
                    Button("Close") { dismiss() }
                }
            } else if store.isLoading || state == nil, store.issues.isEmpty { ProgressView() }
            else if store.boards.isEmpty { ContentUnavailableView("No boards for \(projectKey)", systemImage: "rectangle.split.3x1") }
        }
        .navigationTitle(store.board?.name ?? projectKey)
        .navigationSubtitle(subtitle)
        .toolbar(id: "board") {
            ToolbarItem(id: "boardPicker") {
                // Setters, not onChange: only a user's pick reloads, not the store's own assignments.
                // Menus pull down under the button; a pop-up picker centres its chosen row on the pointer and
                // can run off the top of the screen.
                Menu {
                    Picker("", selection: Binding(get: { store.board }, set: { b in
                        store.board = b
                        if let c = state?.client { Task { await store.loadBoard(c) } }
                    })) {
                        ForEach(store.boards) { b in Text(b.name).tag(Optional(b)) }
                    }
                    .pickerStyle(.inline)
                } label: { Text(store.board?.name ?? "Board").lineLimit(1) }
                .frame(maxWidth: 220)
                .disabled(store.boards.count < 2)
            }
            ToolbarItem(id: "sprintPicker") {
                if !store.sprints.isEmpty {
                    Menu {
                        Picker("", selection: Binding(get: { store.sprint }, set: { sp in
                            store.sprint = sp
                            if let c = state?.client { Task { await store.loadIssues(c) } }
                        })) {
                            ForEach(store.sprints) { s in Text(s.name + (s.state == "active" ? " · active" : "")).tag(Optional(s)) }
                        }
                        .pickerStyle(.inline)
                    } label: { Text(store.sprint.map { $0.name + ($0.state == "active" ? " · active" : "") } ?? "Sprint").lineLimit(1) }
                    .frame(maxWidth: 260)
                }
            }
            ToolbarItem(id: "swimlanes") {
                Menu {
                    Picker("", selection: $swimlanes) {
                        ForEach(Swimlanes.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.inline)
                } label: { Text(swimlanes.rawValue) }
                .help("Group cards into swimlanes")
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

    /// Column headers once at the top, then a row of columns per lane.
    private var lanes: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ForEach(store.columns) { column in
                    BoardColumnHeader(column: column, count: store.issues(in: column).count).frame(width: 280)
                }
            }
            ForEach(swimlanes.lanes(store.issues)) { lane in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(lane.title)  ·  \(lane.issues.count)").font(.headline).lineLimit(1)
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(store.columns) { column in
                            BoardColumn(column: column, issues: store.issues(in: column, from: lane.issues), showsHeader: false, onDrop: drop(column))
                        }
                    }
                }
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var quickFilterBar: some View {
        if !store.quickFilters.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.quickFilters) { f in
                        let on = store.activeFilters.contains(f.id)
                        Button { if let c = state?.client { Task { await store.toggle(f, client: c) } } } label: {
                            Text(f.name).font(.caption.weight(.medium))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .foregroundStyle(on ? Color.white : .primary)
                                .background(on ? Color.accentColor : Color.primary.opacity(0.07), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .help(f.jql)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
    }

    private func drop(_ column: BoardConfiguration.Column) -> (String) -> Void {
        { key in if let c = state?.client { Task { await store.move(key, to: column, client: c) } } }
    }

    private var subtitle: String {
        var s = "\(store.issues.count) issues"
        if store.truncated { s += " (first 2000)" }
        if let sp = store.sprint { s = sp.name + " · " + s }
        return s
    }
}

/// Name, card count, and the WIP limit when the board sets one; red once the column is over it.
struct BoardColumnHeader: View {
    let column: BoardConfiguration.Column
    let count: Int

    var body: some View {
        let over = column.max.map { count > $0 } ?? false
        HStack {
            Text(column.name).font(.headline)
            Text(column.max.map { "\(count) / \($0)" } ?? "\(count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(over ? Color.white : .secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(over ? AnyShapeStyle(.red) : AnyShapeStyle(.quaternary.opacity(0.6)), in: .capsule)
                .help(column.max.map { "WIP limit \($0)" + (over ? ", exceeded" : "") } ?? "")
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

struct BoardColumn: View {
    let column: BoardConfiguration.Column
    let issues: [Issue]
    /// Off inside swimlanes, where the board shows headers once and scrolls as a whole.
    var showsHeader = true
    var onDrop: (String) -> Void
    @Environment(Session.self) private var session
    @Environment(\.jira) private var jira
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                BoardColumnHeader(column: column, count: issues.count)
                ScrollView { cards }
            } else {
                cards
            }
        }
        .padding(10)
        .frame(width: 280)
        .frame(maxHeight: showsHeader ? .infinity : nil, alignment: .top)
        .frame(minHeight: showsHeader ? nil : 60, alignment: .top)
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

    private var cards: some View {
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

    private func open(_ key: String) {
        guard let jira else { return }
        session.pendingOpen = IssueTarget(accountID: jira.id, key: key)
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
    }
}

struct BoardCard: View {
    let issue: Issue

    /// Whole days since the last update, once a card has sat still for a week.
    private var staleDays: Int? {
        guard let u = issue.fields.updated, issue.fields.status.statusCategory.key != "done" else { return nil }
        let days = Calendar.current.dateComponents([.day], from: u, to: .now).day ?? 0
        return days >= 7 ? days : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(issue.fields.summary).font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                RemoteImage(url: issue.fields.issuetype.iconUrl, placeholder: "circle").frame(width: 14, height: 14)
                Text(issue.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                if let d = staleDays {
                    Label("\(d)d", systemImage: "clock").font(.caption2).foregroundStyle(.orange)
                        .help("Not updated for \(d) days")
                }
                Spacer()
                if let p = issue.fields.priority { PriorityIcon(priority: p, size: 12) }
                Avatar(user: issue.fields.assignee, size: 18)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.7), in: .rect(cornerRadius: 10))
        .background(staleDays == nil ? .clear : .orange.opacity(0.12), in: .rect(cornerRadius: 10))
        .contentShape(.rect)
    }
}
