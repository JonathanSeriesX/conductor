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
    private var single: (AccountState, String, Bool)?
    private var loadedKey = ""

    private static func byUpdated(_ a: ListRow, _ b: ListRow) -> Bool {
        let (ua, ub) = (a.issue.fields.updated ?? .distantPast, b.issue.fields.updated ?? .distantPast)
        return ua != ub ? ua > ub : a.id < b.id
    }

    /// One page of a query for one account. With `cache` on, the page is saved to disk, indexed for
    /// Spotlight and remembered as a peek for the issue page. Shared by the list and the launch prefetch.
    static func fetch(jql: String, state: AccountState, nextPageToken: String? = nil, cache: Bool) async throws -> SearchPage {
        let page = try await state.client.search(jql: jql, nextPageToken: nextPageToken)
        for issue in page.issues { state.peek[issue.key] = issue }
        if cache {
            if nextPageToken == nil { DiskCache.saveAsync(page.issues, account: state.account, name: "list-" + DiskCache.hash(jql)) }
            Spotlight.index(page.issues, host: state.host)
        }
        return page
    }

    /// Loads a source: one account with pagination, or every account merged by update time.
    func load(_ source: Source, session: Session, search: String, filters: ListFilters) async {
        generation += 1
        let gen = generation
        nextToken = nil
        single = nil
        let jql = source.jql(search: search, filters: filters)
        // Typed searches are not cached: they change with every keystroke and would litter the disk.
        let cacheable = search.isEmpty
        let isNewQuery = loadedKey != source.id + jql
        loadedKey = source.id + jql
        switch source {
        case .all:
            // Only a new query starts from the cache; a reload keeps the rows in place until fresh ones arrive.
            if isNewQuery {
                var seeded: [ListRow] = []
                if cacheable {
                    for st in session.states {
                        let cached: [Issue] = await DiskCache.loadAsync(account: st.account, name: "list-" + DiskCache.hash(jql)) ?? []
                        seeded += cached.map { ListRow(issue: $0, state: st) }
                    }
                }
                guard gen == generation else { return }
                rows = seeded.sorted(by: Self.byUpdated)
            }
            isLoading = true
            let tasks = session.states.map { st in
                Task<[ListRow], Never> { @MainActor in
                    guard let page = try? await Self.fetch(jql: jql, state: st, cache: cacheable) else { return [] }
                    return page.issues.map { ListRow(issue: $0, state: st) }
                }
            }
            // Merge each account's rows as they arrive instead of waiting for the slowest site.
            var fetched: [ListRow] = []
            for t in tasks {
                fetched += await t.value
                guard gen == generation else { return }
                if isNewQuery { rows = fetched.sorted(by: Self.byUpdated) }
            }
            guard gen == generation else { return }
            rows = fetched.sorted(by: Self.byUpdated)
            isLoading = false
        default:
            guard let id = source.accountID, let st = session.state(id) else { rows = []; return }
            single = (st, jql, cacheable)
            if isNewQuery {
                let cached: [Issue] = cacheable ? (await DiskCache.loadAsync(account: st.account, name: "list-" + DiskCache.hash(jql)) ?? []) : []
                guard gen == generation else { return }
                rows = cached.map { ListRow(issue: $0, state: st) }
            }
            await fetchPage(gen: gen, replacing: true)
        }
    }

    func loadMore() async {
        guard nextToken != nil, !isLoading, single != nil else { return }
        await fetchPage(gen: generation, replacing: false)
    }

    private func fetchPage(gen: Int, replacing: Bool) async {
        guard let (st, jql, cacheable) = single else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await Self.fetch(jql: jql, state: st, nextPageToken: nextToken, cache: cacheable)
            guard gen == generation else { return }
            let fresh = page.issues.map { ListRow(issue: $0, state: st) }
            rows = replacing ? fresh : rows + fresh
            nextToken = page.isLast == true ? nil : page.nextPageToken
        } catch {
            guard gen == generation else { return }
            self.error = error.localizedDescription
        }
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
    private var loadKey: String { "\(source.id)|\(search)|\(filters)|\(session.reloadTick)" }

    var body: some View {
        List(selection: $selection) {
            ForEach(store.rows) { row in
                IssueRow(issue: row.issue, site: source.isUnified ? (row.state.title, row.state.color) : nil)
                    .tag(row.target)
                    .onAppear { if row.id == store.rows.last?.id { Task { await store.loadMore() } } }
                    // Drag a row into Slack, a browser or a note as its Jira link.
                    .itemProvider { NSItemProvider(object: row.state.client.browseURL(row.issue.key) as NSURL) }
            }
            if store.isLoading {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: IssueTarget.self) { targets in
            if let t = targets.first, let row = store.rows.first(where: { $0.target == t }) { rowMenu(row) }
        } primaryAction: { targets in
            // Double-click (or ↩) opens the issue in a window of its own, like a message in Mail.
            for t in targets { openWindow(id: "issue", value: t) }
        }
        .safeAreaInset(edge: .top, spacing: 0) { chips }
        .overlay {
            if !store.isLoading, store.rows.isEmpty {
                ContentUnavailableView(search.isEmpty && !filters.isActive ? "No issues" : "No matches", systemImage: "tray")
            }
        }
        .focusedSceneValue(\.listActions, ListActions(
            saveFilter: search.isEmpty || source.isUnified ? nil : { filterName = ""; savingFilter = true },
            openBoard: boardTarget.map { b in { openWindow(id: "board", value: b) } }
        ))
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
                if let b = boardTarget {
                    Button { openWindow(id: "board", value: b) } label: { Label("Board", systemImage: "rectangle.split.3x1") }
                        .help("Open the project board (⌘⇧B)")
                }
            }
            ToolbarItem(id: "saveFilter") {
                Button { filterName = ""; savingFilter = true } label: { Label("Save as Filter", systemImage: "bookmark") }
                    .help(source.isUnified ? "Pick an account's list to save a filter" : "Save this search as a favourite filter (⌘S)")
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

    private var boardTarget: BoardTarget? {
        if case .project(let p, let id) = source { return BoardTarget(accountID: id, projectKey: p.key) }
        return nil
    }

    private var subtitle: String {
        guard !store.rows.isEmpty else { return "" }
        return "\(store.rows.count)\(store.nextToken == nil ? "" : "+") issues"
    }

    // MARK: Row actions

    @ViewBuilder
    private func rowMenu(_ row: ListRow) -> some View {
        let key = row.issue.key
        let url = row.state.client.browseURL(key)
        let watching = row.issue.fields.watches?.isWatching == true
        let me = row.state.me?.accountId
        Button("Open in New Window", systemImage: "macwindow.badge.plus") { openWindow(id: "issue", value: row.target) }
        Button("Open in Browser", systemImage: "safari") { NSWorkspace.shared.open(url) }
        Divider()
        Button("Copy Link", systemImage: "link") { copyToPasteboard(url.absoluteString) }
        Button("Copy Key", systemImage: "number") { copyToPasteboard(key) }
        Button("Copy as Markdown", systemImage: "text.quote") { copyToPasteboard(row.state.client.markdownLink(key, summary: row.issue.fields.summary)) }
        ShareLink(item: url)
        Divider()
        Button(watching ? "Stop Watching This Issue" : "Watch This Issue", systemImage: watching ? "eye.slash" : "eye") {
            act { try await row.state.client.watch(key, !watching, me: me) }
        }
        if let me, row.issue.fields.assignee?.accountId != me {
            Button("Assign to Me", systemImage: "person.crop.circle.badge.checkmark") {
                act { try await row.state.client.assign(key, to: me) }
            }
        }
    }

    /// Runs a write, then reloads the list and the open issue so both show the result.
    private func act(_ op: @escaping () async throws -> Void) {
        Task {
            do { try await op(); session.reloadTick += 1 } catch { store.error = error.localizedDescription }
        }
    }

    // MARK: Chips

    private var typeNames: [String] { state?.issueTypeNames ?? [] }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                FilterChip(id: "status", title: filters.status.rawValue, active: filters.status != .any, menus: chipMenus,
                           items: ListFilters.Status.allCases.map { s in ChipItem(s.rawValue, selected: filters.status == s) { filters.status = s } })
                FilterChip(id: "assignee", title: filters.assignee.rawValue, active: filters.assignee != .any, menus: chipMenus,
                           items: ListFilters.Assignee.allCases.map { a in ChipItem(a.rawValue, selected: filters.assignee == a) { filters.assignee = a } })
                if !source.isUnified { // issue types differ per site, so the chip only makes sense inside one account
                    FilterChip(id: "type", title: filters.type ?? "Any type", active: filters.type != nil, menus: chipMenus,
                               items: [ChipItem("Any type", selected: filters.type == nil) { filters.type = nil }, .separator]
                                   + typeNames.map { t in ChipItem(t, selected: filters.type == t) { filters.type = t } })
                }
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
    var site: (name: String, color: Color)?
    @Environment(\.backgroundProminence) private var prominence

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
                        let tint: Color = prominence == .increased ? .white : site.color
                        Text(site.name).font(.caption2.weight(.semibold)).foregroundStyle(tint)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(tint.opacity(prominence == .increased ? 0.28 : 0.16), in: .capsule)
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
