import SwiftUI
import AppKit

/// One row of a list: the issue and the account it came from.
struct ListRow: Identifiable {
    let issue: Issue
    let state: AccountState
    var id: String { "\(state.id)|\(issue.key)" }
    var target: IssueTarget { IssueTarget(accountID: state.id, key: issue.key) }
}

@MainActor @Observable
final class IssueListStore {
    var rows: [ListRow] = []
    var nextToken: String?
    var isLoading = false
    var error: String?
    private var generation = 0
    private var single: (AccountState, String)?

    /// Loads a source: one account with pagination, or every account merged by update time.
    func load(_ source: Source, session: Session, search: String, filters: ListFilters) async {
        generation += 1
        let gen = generation
        nextToken = nil
        single = nil
        switch source {
        case .all(.recent) where search.isEmpty:
            rows = await recent(session)
        case .all:
            let jql = source.jql(search: search, filters: filters)
            rows = session.states.flatMap { st in
                (DiskCache.load([Issue].self, account: st.account, name: "list-" + DiskCache.hash(jql)) ?? []).map { ListRow(issue: $0, state: st) }
            }
            isLoading = true
            let tasks = session.states.map { st in
                Task<[ListRow], Never> { @MainActor in
                    guard let page = try? await st.client.search(jql: jql) else { return [] }
                    DiskCache.save(page.issues, account: st.account, name: "list-" + DiskCache.hash(jql))
                    Spotlight.index(page.issues, host: st.host)
                    return page.issues.map { ListRow(issue: $0, state: st) }
                }
            }
            var fetched: [ListRow] = []
            for t in tasks { fetched += await t.value }
            guard gen == generation else { return }
            rows = fetched.sorted { ($0.issue.fields.updated ?? .distantPast) > ($1.issue.fields.updated ?? .distantPast) }
            isLoading = false
        default:
            guard let id = source.accountID, let st = session.state(id) else { rows = []; return }
            let jql = source.jql(search: search, filters: filters)
            single = (st, jql)
            rows = (DiskCache.load([Issue].self, account: st.account, name: "list-" + DiskCache.hash(jql)) ?? []).map { ListRow(issue: $0, state: st) }
            await fetchPage(gen: gen, replacing: true)
        }
    }

    func loadMore() async {
        guard nextToken != nil, !isLoading, single != nil else { return }
        await fetchPage(gen: generation, replacing: false)
    }

    private func fetchPage(gen: Int, replacing: Bool) async {
        guard let (st, jql) = single else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await st.client.search(jql: jql, nextPageToken: nextToken)
            guard gen == generation else { return }
            let fresh = page.issues.map { ListRow(issue: $0, state: st) }
            rows = replacing ? fresh : rows + fresh
            nextToken = page.isLast == true ? nil : page.nextPageToken
            if replacing { DiskCache.save(page.issues, account: st.account, name: "list-" + DiskCache.hash(jql)) }
            Spotlight.index(page.issues, host: st.host)
        } catch {
            guard gen == generation else { return }
            self.error = error.localizedDescription
        }
    }

    /// The app's own cross-account history, fetched per account in one query each.
    private func recent(_ session: Session) async -> [ListRow] {
        let wanted = session.history.prefix(60)
        let tasks = session.states.compactMap { st -> Task<[ListRow], Never>? in
            let keys = wanted.filter { $0.accountID == st.id }.map(\.key)
            guard !keys.isEmpty else { return nil }
            return Task { @MainActor in
                let jql = "key IN (" + keys.map { "\"\($0)\"" }.joined(separator: ",") + ")"
                guard let page = try? await st.client.search(jql: jql) else { return [] }
                return page.issues.map { ListRow(issue: $0, state: st) }
            }
        }
        var fetched: [IssueTarget: ListRow] = [:]
        for t in tasks { for r in await t.value { fetched[r.target] = r } }
        return wanted.compactMap { fetched[$0] }
    }
}

struct IssueListView: View {
    let source: Source
    @Binding var selection: IssueTarget?
    @Environment(Session.self) private var session
    @Environment(\.openWindow) private var openWindow
    @State private var store = IssueListStore()
    @State private var search = ""
    @State private var filters = ListFilters()
    @State private var suggestions: [(display: String, completion: String)] = []
    @State private var savingFilter = false
    @State private var filterName = ""
    @State private var chipMenus = ChipMenuController()
    @FocusState private var searchFocused: Bool

    private var isRawJQL: Bool { Source.looksLikeJQL(search) }
    private var state: AccountState? { source.accountID.flatMap(session.state) ?? session.states.first }
    private var loadKey: String { "\(source.id)|\(search)|\(filters)|\(session.reloadTick)|\(session.history.count)" }

    var body: some View {
        List(selection: $selection) {
            ForEach(store.rows) { row in
                IssueRow(issue: row.issue, site: source.isUnified ? row.state.title : nil)
                    .tag(row.target)
                    .onAppear { if row.id == store.rows.last?.id { Task { await store.loadMore() } } }
            }
            if store.isLoading {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .safeAreaInset(edge: .top, spacing: 0) { chips }
        .overlay {
            if !store.isLoading, store.rows.isEmpty {
                ContentUnavailableView(search.isEmpty && !filters.isActive ? "No issues" : "No matches", systemImage: "tray")
            }
        }
        .navigationTitle(source.title)
        .navigationSubtitle(subtitle)
        .searchable(text: $search, placement: .toolbar, prompt: "Search, JQL, or paste a Jira link")
        .searchFocused($searchFocused)
        .searchSuggestions {
            ForEach(suggestions, id: \.completion) { s in
                Text(s.display).searchCompletion(s.completion)
            }
        }
        .onSubmit(of: .search) {
            if let url = URL(string: search), url.scheme?.hasPrefix("http") == true, Session.issueKey(in: url) != nil {
                session.open(url: url)
                search = ""
                return
            }
            session.recordSearch(search)
        }
        .toolbar(id: "list") {
            ToolbarItem(id: "board") {
                if case .project(let p, let id) = source {
                    Button { openWindow(id: "board", value: BoardTarget(accountID: id, projectKey: p.key)) } label: { Label("Board", systemImage: "rectangle.split.3x1") }
                        .help("Open the project board")
                }
            }
            ToolbarItem(id: "saveFilter") {
                Button { filterName = ""; savingFilter = true } label: { Label("Save as Filter", systemImage: "bookmark") }
                    .help(source.isUnified ? "Pick an account's list to save a filter" : "Save this search as a favourite filter")
                    .disabled(search.isEmpty || source.isUnified)
            }
        }
        .alert("Save as Filter", isPresented: $savingFilter) {
            TextField("Filter name", text: $filterName)
            Button("Save") { saveFilter() }.disabled(filterName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The filter is starred and shows up in the sidebar on every device.")
        }
        .task(id: loadKey) {
            // Debounce typing; JQL is evaluated server-side.
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            await store.load(source, session: session, search: search, filters: filters)
        }
        .task(id: search) { await updateSuggestions() }
        .onChange(of: session.focusSearchRequested) { _, on in
            if on { searchFocused = true; session.focusSearchRequested = false }
        }
        .errorAlert($store.error)
    }

    private var subtitle: String {
        guard !store.rows.isEmpty else { return "" }
        return "\(store.rows.count)\(store.nextToken == nil ? "" : "+") issues"
    }

    // MARK: Chips

    private var typeNames: [String] {
        source.isUnified ? Array(Set(session.states.flatMap(\.issueTypeNames))).sorted() : (state?.issueTypeNames ?? [])
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                FilterChip(id: "status", title: filters.status.rawValue, active: filters.status != .any, menus: chipMenus,
                           items: ListFilters.Status.allCases.map { s in ChipItem(s.rawValue, selected: filters.status == s) { filters.status = s } })
                FilterChip(id: "assignee", title: filters.assignee.rawValue, active: filters.assignee != .any, menus: chipMenus,
                           items: ListFilters.Assignee.allCases.map { a in ChipItem(a.rawValue, selected: filters.assignee == a) { filters.assignee = a } })
                FilterChip(id: "type", title: filters.type ?? "Any type", active: filters.type != nil, menus: chipMenus,
                           items: [ChipItem("Any type", selected: filters.type == nil) { filters.type = nil }, .separator]
                               + typeNames.map { t in ChipItem(t, selected: filters.type == t) { filters.type = t } })
                FilterChip(id: "updated", title: filters.updated.rawValue, active: filters.updated != .any, menus: chipMenus,
                           items: ListFilters.Updated.allCases.map { u in ChipItem(u.rawValue, selected: filters.updated == u) { filters.updated = u } })
                if filters.isActive {
                    Button { filters = ListFilters() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Clear filters")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .disabled(isRawJQL)
        .opacity(isRawJQL ? 0.4 : 1)
        .help(isRawJQL ? "Filters don't apply to raw JQL" : "")
    }

    // MARK: Search assist

    private func updateSuggestions() async {
        let q = search
        if q.isEmpty {
            suggestions = session.recentSearches.map { ($0, $0) }
            return
        }
        let fields = state?.jqlFields ?? []
        guard isRawJQL || fields.contains(where: { q.lowercased().hasPrefix($0.value.lowercased()) }) else { suggestions = []; return }
        // "status = In" → values for status; "sta" → field names.
        if let m = q.firstMatch(of: /(.*?)([A-Za-z_][\w\[\]. ]*?)\s*(=|!=|~|!~|>=|<=|>|<|\bin\b|\bnot in\b|\bis not\b|\bis\b)\s*("?)([^"]*)$/.ignoresCase()) {
            let field = String(m.2).trimmingCharacters(in: .whitespaces)
            let partial = String(m.5)
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let c = state?.client else { return }
            let values = (try? await c.jqlSuggestions(field: field, value: partial)) ?? []
            let prefix = String(m.1) + field + " " + String(m.3) + " "
            suggestions = values.prefix(8).map { ($0.displayName.replacingOccurrences(of: "<b>", with: "").replacingOccurrences(of: "</b>", with: ""), prefix + $0.value + " ") }
            return
        }
        guard let last = q.split(separator: " ", omittingEmptySubsequences: false).last else { suggestions = []; return }
        let head = q.dropLast(last.count)
        let word = last.lowercased()
        guard !word.isEmpty else { suggestions = []; return }
        suggestions = fields
            .filter { $0.value.lowercased().hasPrefix(word) }
            .prefix(8)
            .map { ($0.displayName, head + $0.value + " ") }
    }

    private func saveFilter() {
        guard let st = state, let id = source.accountID else { return }
        let name = filterName.trimmingCharacters(in: .whitespaces)
        let jql = source.jql(search: search, filters: filters)
        Task {
            do {
                let f = try await st.client.createFilter(name: name, jql: jql)
                search = ""
                await st.refreshCatalog()
                session.navigationRequest = .filter(f, id)
            } catch { store.error = error.localizedDescription }
        }
    }
}

struct IssueRow: View {
    let issue: Issue
    var site: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RemoteImage(url: issue.fields.issuetype.iconUrl, placeholder: "circle")
                .frame(width: 16, height: 16)
                .padding(.top, 2)
                .help(issue.fields.issuetype.name)
            VStack(alignment: .leading, spacing: 5) {
                Text(issue.fields.summary).lineLimit(2)
                HStack(spacing: 8) {
                    Text(issue.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if let site {
                        Text(site).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary.opacity(0.6), in: .capsule)
                    }
                    StatusPill(status: issue.fields.status)
                    Spacer(minLength: 0)
                    if let p = issue.fields.priority { PriorityIcon(priority: p) }
                    Avatar(user: issue.fields.assignee, size: 18)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Chips backed by real NSMenus

struct ChipItem {
    let title: String
    let selected: Bool
    let action: (() -> Void)?
    init(_ title: String, selected: Bool, action: @escaping () -> Void) { self.title = title; self.selected = selected; self.action = action }
    private init() { title = ""; selected = false; action = nil }
    static var separator: ChipItem { ChipItem() }
}

/// Pops native menus under chips. When a menu closes because the pointer is over another chip, that chip's
/// menu opens at once, so switching filters never costs an extra click.
@MainActor
final class ChipMenuController: NSObject, NSMenuDelegate {
    private var anchors: [String: NSView] = [:]
    private var items: [String: [ChipItem]] = [:]
    private var openID: String?
    private var actions: [NSMenuItem: () -> Void] = [:]

    func register(_ id: String, view: NSView, items: [ChipItem]) {
        anchors[id] = view
        self.items[id] = items
    }

    func toggle(_ id: String) {
        if openID == id { return } // the click that closed it must not reopen it
        open(id)
    }

    private func open(_ id: String) {
        guard let anchor = anchors[id], let list = items[id] else { return }
        let menu = NSMenu()
        menu.delegate = self
        actions = [:]
        for item in list {
            if item.action == nil { menu.addItem(.separator()); continue }
            let mi = NSMenuItem(title: item.title, action: #selector(fire(_:)), keyEquivalent: "")
            mi.target = self
            mi.state = item.selected ? .on : .off
            actions[mi] = item.action
            menu.addItem(mi)
        }
        openID = id
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: anchor)
    }

    @objc private func fire(_ sender: NSMenuItem) { actions[sender]?() }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        Task { @MainActor in
            let closed = self.openID
            self.openID = nil
            let mouse = NSEvent.mouseLocation
            for (id, view) in self.anchors where id != closed {
                guard let window = view.window else { continue }
                let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
                if frame.contains(mouse) { self.open(id); return }
            }
        }
    }
}

struct FilterChip: View {
    let id: String
    let title: String
    let active: Bool
    let menus: ChipMenuController
    let items: [ChipItem]

    var body: some View {
        Button { menus.toggle(id) } label: {
            HStack(spacing: 3) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(active ? Color.white : .primary)
            .background(active ? Color.accentColor : Color.primary.opacity(0.07), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .background(ChipAnchor(id: id, menus: menus, items: items))
    }
}

/// Transparent view that gives the chip an NSView to anchor its menu to.
private struct ChipAnchor: NSViewRepresentable {
    let id: String
    let menus: ChipMenuController
    let items: [ChipItem]
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) { menus.register(id, view: view, items: items) }
}
