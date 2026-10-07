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
    private var state: AccountState?
    private var projectKey = ""

    /// Everything a board window needs to draw, saved per project so it opens from disk and refreshes behind.
    struct Snapshot: Codable {
        var boards: [Board]; var board: Board?; var config: BoardConfiguration?
        var sprints: [Sprint]; var sprint: Sprint?; var quickFilters: [QuickFilter]; var issues: [Issue]
    }

    private func saveSnapshot() {
        guard let state, !projectKey.isEmpty else { return }
        let snap = Snapshot(boards: boards, board: board, config: config, sprints: sprints, sprint: sprint, quickFilters: quickFilters, issues: issues)
        DiskCache.saveAsync(snap, account: state.account, name: "board-\(projectKey)")
    }

    /// Warms a starred project's board after launch, and the full text of its cards assigned to me.
    static func prefetch(_ project: String, state: AccountState) async {
        let store = BoardStore()
        await store.load(state, project: project)
        let mine = store.issues.filter { $0.fields.assignee?.accountId == state.me?.accountId }
        IssueListStore.prefetchDetails(mine.map { ListRow(issue: $0, state: state) })
    }

    var columns: [BoardConfiguration.Column] { config?.columnConfig.columns ?? [] }

    /// With `fold`, subtasks whose parent is on the board disappear into the parent card's progress count.
    func issues(in column: BoardConfiguration.Column, from list: [Issue]? = nil, fold: Bool = false) -> [Issue] {
        let ids = Set(column.statuses.map(\.id))
        let parents = fold ? Set(issues.map(\.key)) : []
        return (list ?? issues).filter { i in
            ids.contains(i.fields.status.id) && !(fold && i.fields.issuetype.isSubtask && i.fields.parent.map { parents.contains($0.key) } == true)
        }
    }

    func load(_ state: AccountState, project: String) async {
        self.state = state
        projectKey = project
        let client = state.client
        if issues.isEmpty, let snap: Snapshot = await DiskCache.loadAsync(account: state.account, name: "board-\(project)") {
            // Last run's board at once; the network pass below replaces it piece by piece.
            boards = snap.boards; board = snap.board; config = snap.config
            sprints = snap.sprints; sprint = snap.sprint; quickFilters = snap.quickFilters; issues = snap.issues
        }
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
        if gen == generation { issues = all; saveSnapshot() }
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
        ScrollView(.horizontal) {
            if swimlanes == .none {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(store.columns) { column in
                        BoardColumn(column: column, issues: store.issues(in: column, fold: true), onDrop: drop(column), onWrite: reload)
                    }
                }
                .padding(16)
            } else {
                // Headers stay put; only the lanes scroll vertically, inside the sideways scroll.
                VStack(alignment: .leading, spacing: 8) {
                    let laneList = swimlanes.lanes(store.issues)
                    HStack(spacing: 12) {
                        ForEach(store.columns) { column in
                            // Counted the way the lanes draw them, so the header agrees with the cards below it.
                            BoardColumnHeader(column: column, count: laneList.reduce(0) { $0 + store.issues(in: column, from: $1.issues, fold: swimlanes != .parent).count }).frame(width: 280)
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 16)
                    ScrollView(.vertical) { lanes }
                }
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
                    ForEach(store.boards) { b in
                        Toggle(b.name, isOn: Binding(get: { store.board == b }, set: { on in
                            guard on else { return }
                            store.board = b
                            if let c = state?.client { Task { await store.loadBoard(c) } }
                        }))
                    }
                } label: { Text(store.board?.name ?? "Board").lineLimit(1) }
                .frame(maxWidth: 220)
                .disabled(store.boards.count < 2)
            }
            ToolbarItem(id: "sprintPicker") {
                if !store.sprints.isEmpty {
                    Menu {
                        ForEach(store.sprints) { s in
                            Toggle(s.name + (s.state == "active" ? " · active" : ""), isOn: Binding(get: { store.sprint == s }, set: { on in
                                guard on else { return }
                                store.sprint = s
                                if let c = state?.client { Task { await store.loadIssues(c) } }
                            }))
                        }
                    } label: { Text(store.sprint.map { $0.name + ($0.state == "active" ? " · active" : "") } ?? "Sprint").lineLimit(1) }
                    .frame(maxWidth: 260)
                }
            }
            ToolbarItem(id: "swimlanes") {
                Menu {
                    ForEach(Swimlanes.allCases, id: \.self) { s in
                        Toggle(s.rawValue, isOn: Binding(get: { swimlanes == s }, set: { if $0 { swimlanes = s } }))
                    }
                } label: { Text(swimlanes.rawValue) }
                .help("Group cards into swimlanes")
            }
            ToolbarItem(id: "openInBrowser") {
                Button { if let c = state?.client { NSWorkspace.shared.open(c.boardURL(project: projectKey, board: store.board?.id)) } } label: { Label("Open in Browser", systemImage: "safari") }
                    .help("Open this board on the web")
            }
            ToolbarItem(id: "refresh") {
                Button { if let c = state?.client { Task { await store.loadIssues(c) } } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
                    .help("Refresh (⌘R)")
            }
        }
        // Re-runs once sign-in completes after a restored launch.
        .task(id: "\(projectKey)|\(state?.id.uuidString ?? "")") {
            if let state { await store.load(state, project: projectKey) }
        }
        .errorAlert($store.error)
        .frame(minWidth: 700, minHeight: 400)
    }

    /// A row of columns per lane; the headers sit above, outside the vertical scroll.
    private var lanes: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(swimlanes.lanes(store.issues)) { lane in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(lane.title)  ·  \(lane.issues.count)").font(.headline).lineLimit(1)
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(store.columns) { column in
                            BoardColumn(column: column, issues: store.issues(in: column, from: lane.issues, fold: swimlanes != .parent), showsHeader: false, onDrop: drop(column), onWrite: reload)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 16)
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

    private func reload() { if let c = state?.client { Task { await store.loadIssues(c) } } }

    private func drop(_ column: BoardConfiguration.Column) -> (String) -> Void {
        { key in if let c = state?.client { Task { await store.move(key, to: column, client: c) } } }
    }

    /// Cards drawn right now: with lanes, subtasks stand on their own; without, they fold into their parent.
    private var cardCount: Int {
        if swimlanes == .none { return store.columns.reduce(0) { $0 + store.issues(in: $1, fold: true).count } }
        let laneList = swimlanes.lanes(store.issues)
        return store.columns.reduce(0) { sum, column in sum + laneList.reduce(0) { $0 + store.issues(in: column, from: $1.issues, fold: swimlanes != .parent).count } }
    }

    private var subtitle: String {
        var s = issues(cardCount)
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
    /// Reloads the board after a menu action changed an issue.
    var onWrite: () -> Void = {}
    @Environment(Session.self) private var session
    @Environment(\.jira) private var jira
    @Environment(\.openWindow) private var openWindow
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
        .frosted(cornerRadius: 16, opacity: 0.45)   // lighter than the cards on it
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
                    .onTapGesture(count: 2) { if let jira { openWindow(id: "issue", value: IssueTarget(accountID: jira.id, key: issue.key)) } }
                    .contextMenu {
                        if let jira { IssueMenu(issue: issue, state: jira) { op in Task { try? await op(); onWrite() } } }
                    }
            }
        }
        .padding(2)
    }

}

struct BoardCard: View {
    let issue: Issue

    /// Whole days since the last update, once a card has sat still for a week.
    private var staleDays: Int? {
        guard let u = issue.fields.updated, !issue.isDone else { return nil }
        let days = Calendar.current.dateComponents([.day], from: u, to: .now).day ?? 0
        return days >= 7 ? days : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(issue.fields.summary).font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .strikethrough(issue.isDone).foregroundStyle(issue.isDone ? .secondary : .primary)
            HStack(spacing: 6) {
                RemoteImage(url: issue.fields.issuetype.iconUrl, placeholder: "circle").frame(width: 14, height: 14)
                    .accessibilityLabel(issue.fields.issuetype.name)
                Text(issue.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                if let p = issue.subtaskProgress {
                    Label("\(p.done)/\(p.total)", systemImage: "checklist").font(.caption2)
                        .foregroundStyle(p.done == p.total ? .green : .secondary).help("\(p.done) of \(p.total) subtasks done")
                }
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
