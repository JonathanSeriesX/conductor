import SwiftUI
import AppKit

/// One row of a list: the issue and the account it came from.
struct ListRow: Identifiable {
    let issue: Issue
    let state: AccountState
    var id: String { "\(state.id)|\(issue.key)" }
    var target: IssueTarget { IssueTarget(accountID: state.id, key: issue.key) }
}

/// A row as the list draws it. A parent folds the subtasks that sit in the same list under itself;
/// a subtask whose parent is elsewhere stays at the top level with a crumb naming the parent.
struct DisplayRow: Identifiable {
    let row: ListRow
    var children: [ListRow] = []
    var depth = 0
    var id: String { row.id }

    /// `expanded` holds the ids of parents whose subtasks are shown.
    static func nest(_ rows: [ListRow], expanded: Set<String>, sort: ListFilters.Sort) -> [DisplayRow] {
        let present = Set(rows.map(\.id))
        var children: [String: [ListRow]] = [:]
        var top: [ListRow] = []
        for r in rows {
            if r.issue.fields.issuetype.isSubtask, let p = r.issue.fields.parent?.key, present.contains("\(r.state.id)|\(p)") {
                children["\(r.state.id)|\(p)", default: []].append(r)
            } else {
                top.append(r)
            }
        }
        // Sorted by update, a parent whose children were touched more recently moves with them; any other
        // order is the server's and stays as it came.
        if sort.field == .updated {
            func latest(_ r: ListRow) -> Date {
                max(r.issue.fields.updated ?? .distantPast, children[r.id]?.compactMap(\.issue.fields.updated).max() ?? .distantPast)
            }
            top.sort { a, b in
                let (la, lb) = (latest(a), latest(b))
                return la != lb ? (sort.descending ? la > lb : la < lb) : a.id < b.id
            }
        }
        var out: [DisplayRow] = []
        for r in top {
            let kids = children[r.id] ?? []
            out.append(DisplayRow(row: r, children: kids))
            if expanded.contains(r.id) { out += kids.map { DisplayRow(row: $0, depth: 1) } }
        }
        return out
    }
}

@MainActor @Observable
final class IssueListStore {
    var rows: [ListRow] = []
    var nextToken: String?
    var isLoading = false
    var error: String?
    /// The filters restrict nothing, which Jira refuses; the list explains instead of asking.
    var unbounded = false
    /// Jira rejected a typed query (half-written JQL, usually). Shown in the list, never as an alert.
    var queryError: String?
    private var generation = 0
    private var single: (AccountState, String, Bool)?
    private var loadedKey = ""
    private var sort = ListFilters.Sort()

    /// One page of a query for one account. With `cache` on, the page is saved to disk, indexed for
    /// Spotlight and remembered as a peek for the issue page. Shared by the list and the launch prefetch.
    static func fetch(jql: String, state: AccountState, nextPageToken: String? = nil, cache: Bool) async throws -> SearchPage {
        let page = try await state.client.search(jql: jql, nextPageToken: nextPageToken)
        for issue in page.issues where !(state.peek[issue.key].map { $0.fields.updated == issue.fields.updated && $0.fields.comment != nil } ?? false) {
            state.peek[issue.key] = issue   // keep a full copy of the same revision; a row has fewer fields
        }
        state.warmTransitions(page.issues)
        if cache {
            if nextPageToken == nil { DiskCache.saveAsync(page.issues, account: state.account, name: "list-" + DiskCache.hash(jql)) }
            Spotlight.index(page.issues, host: state.host)
        }
        return page
    }

    /// Fetches full details for the top rows in one request per account and saves each as `issue-KEY`,
    /// so opening one shows description and comments from disk. Rows unchanged since the last prefetch are skipped.
    static func prefetchDetails(_ rows: [ListRow], limit: Int = 50) {
        let stale = rows.prefix(limit).filter { $0.state.prefetched[$0.issue.key] != $0.issue.fields.updated }
        for group in Dictionary(grouping: stale, by: \.state.id).values {
            guard let st = group.first?.state else { continue }
            let jql = "issuekey in (" + group.map { "\"\($0.issue.key)\"" }.joined(separator: ",") + ")"
            Task { @MainActor in
                guard let page = try? await st.client.search(jql: jql, fields: st.client.detailFields) else { return }
                for issue in page.issues {
                    DiskCache.saveAsync(issue, account: st.account, name: "issue-\(issue.key)")
                    st.peek[issue.key] = issue
                    st.prefetched[issue.key] = issue.fields.updated
                }
                DiskCache.saveAsync(st.prefetched, account: st.account, name: "prefetched")
            }
        }
    }

    /// Loads the filters: one account with pagination, or every account merged in the chosen order.
    func load(_ f: ListFilters, session: Session) async {
        generation += 1
        let gen = generation
        nextToken = nil
        single = nil
        sort = f.sort
        unbounded = !f.isBounded
        queryError = nil
        if unbounded { rows = []; return }
        let states = f.account.map { id in session.states.filter { $0.id == id } } ?? session.states
        let queries: [(AccountState, String)] = states.map { ($0, f.jql) }
        // Typed searches are not cached: they change with every keystroke and would litter the disk.
        let cacheable = f.text.isEmpty
        let queryKey = queries.map { "\($0.0.id)|\($0.1)" }.joined()
        let isNewQuery = loadedKey != queryKey
        loadedKey = queryKey
        if f.account == nil {
            // Each account's rows stay put (from cache on a new query, else what is shown) until its own fresh
            // page lands, so the list never collapses to the fastest site and then grows back.
            var byAccount: [UUID: [ListRow]] = Dictionary(grouping: rows, by: \.state.id)
            if isNewQuery {
                byAccount = [:]
                if cacheable {
                    for (st, jql) in queries {
                        let cached: [Issue] = await DiskCache.loadAsync(account: st.account, name: "list-" + DiskCache.hash(jql)) ?? []
                        byAccount[st.id] = cached.map { ListRow(issue: $0, state: st) }
                    }
                }
                guard gen == generation else { return }
                rows = merged(byAccount)
            }
            isLoading = true
            let tasks = queries.map { st, jql in
                (st.id, Task<[ListRow]?, Never> { @MainActor in
                    guard let page = try? await Self.fetch(jql: jql, state: st, cache: cacheable) else { return nil }
                    return page.issues.map { ListRow(issue: $0, state: st) }
                })
            }
            for (id, t) in tasks {
                let fresh = await t.value
                guard gen == generation else { return }
                if let fresh { byAccount[id] = fresh }   // a failed site keeps what it had
                rows = merged(byAccount)
            }
            isLoading = false
            if cacheable { Self.prefetchDetails(rows) }
        } else {
            guard let (st, jql) = queries.first else { rows = []; return }
            single = (st, jql, cacheable)
            if isNewQuery {
                let cached: [Issue] = cacheable ? (await DiskCache.loadAsync(account: st.account, name: "list-" + DiskCache.hash(jql)) ?? []) : []
                guard gen == generation else { return }
                rows = cached.map { ListRow(issue: $0, state: st) }
            }
            await fetchPage(gen: gen, replacing: true)
        }
    }

    private func merged(_ byAccount: [UUID: [ListRow]]) -> [ListRow] {
        byAccount.values.flatMap { $0 }.sorted { sort.areInOrder($0.issue, $1.issue) }
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
            if replacing, cacheable { Self.prefetchDetails(rows) }
        } catch {
            guard gen == generation, !error.isOffline, !error.isCancelled else { return }
            // A 400 on a typed search is the query itself; an alert would steal the keystrokes that fix it.
            if !cacheable, (error as? JiraError)?.status == 400 { queryError = error.localizedDescription; rows = [] }
            else { self.error = error.localizedDescription }
        }
    }
}

struct IssueListView: View {
    @Binding var filters: ListFilters
    @Environment(Session.self) private var session
    @Environment(\.openWindow) private var openWindow
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var store = IssueListStore()
    @State private var selection: IssueTarget?
    @State private var suggestions: [(display: String, completion: String)] = []
    @State private var savingFilter = false
    @State private var filterName = ""
    @State private var chipMenus = ChipMenuController()
    @FocusState private var searchFocused: Bool
    /// Parents whose subtasks are unfolded. Per parent, so opening one never shifts the rows above it.
    @State private var expanded: Set<String> = []
    private var displayRows: [DisplayRow] { DisplayRow.nest(store.rows, expanded: expanded, sort: filters.sort) }

    private var isUnified: Bool { filters.account == nil }
    /// The account the chips describe; the first one stands in for unified lists (search assist, issue types).
    private var state: AccountState? { filters.account.flatMap(session.state) ?? session.states.first }
    /// Ticks when the app comes to the front or every few minutes, so the list never sits stale for long.
    @State private var refreshTick = 0
    private var loadKey: String { "\(filters)|\(session.reloadTick)|\(session.listTick)|\(refreshTick)" }
    /// What the clear button goes back to: the chips reset, the account and the search stay.
    private var cleared: ListFilters {
        var f = ListFilters()
        f.account = filters.account
        f.text = filters.text
        return f
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(displayRows) { d in
                let row = d.row
                IssueRow(issue: row.issue, site: isUnified && session.states.count > 1 ? (row.state.title, row.state.color) : nil,
                         depth: d.depth, folded: d.children.count, expanded: expanded.contains(d.id),
                         toggle: d.children.isEmpty ? nil : { withAnimation(.snappy(duration: 0.25)) { expanded.formSymmetricDifference([d.id]) } })
                    .tag(row.target)
                    .onAppear { if d.id == displayRows.last?.id { Task { await store.loadMore() } } }
                    // Drag a row into Slack, a browser or a note as its Jira link.
                    .itemProvider {
                        let p = NSItemProvider(object: row.state.client.browseURL(row.issue.key) as NSURL)
                        p.suggestedName = "\(row.issue.key) \(row.issue.fields.summary)"   // the .webloc's name in the Finder
                        return p
                    }
            }
            if store.isLoading {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    .listRowSeparator(.hidden)
            }
            if filters.scope == .recent, !store.rows.isEmpty, !store.isLoading {
                // Jira's history only records issues opened on the web; nothing Conductor does can add to it.
                Text("Jira keeps this list from the issues you open on the web. Issues opened in Conductor don't count.")
                    .font(.caption).foregroundStyle(.tertiary).padding(.vertical, 8)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: IssueTarget.self) { targets in
            if let t = targets.first, let row = store.rows.first(where: { $0.target == t }) { rowMenu(row) }
        } primaryAction: { targets in
            // Double-click (or ↩) opens the issue in its own window; a single click only selects.
            for t in targets { openWindow(id: "issue", value: t) }
        }
        .onKeyPress(.rightArrow) { fold(open: layoutDirection == .leftToRight) }
        .onKeyPress(.leftArrow) { fold(open: layoutDirection == .rightToLeft) }
        .safeAreaInset(edge: .top, spacing: 0) { chips }
        .overlay {
            if store.unbounded {
                ContentUnavailableView("Pick a filter", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("Jira won't list a whole site at once. Choose a project, a status, a person or a scope, or type a search."))
            } else if let e = store.queryError {
                ContentUnavailableView("Incomplete query", systemImage: "text.magnifyingglass", description: Text(e))
            } else if !store.isLoading, store.rows.isEmpty {
                ContentUnavailableView {
                    Label(filters.isActive ? "No matches" : "No issues", systemImage: "tray")
                } description: {
                    if filters != cleared { Text("Nothing matches these filters.") }
                } actions: {
                    if !filters.text.isEmpty { Button("Clear Search") { filters.text = "" } }
                    else if filters != cleared { Button("Clear Filters") { filters = cleared } }
                }
            }
        }
        .focusedSceneValue(\.listActions, ListActions(
            saveFilter: canSaveFilter ? { filterName = ""; savingFilter = true } : nil,
            openBoard: boardTarget.map { b in { openWindow(id: "board", value: b) } }
        ))
        .navigationTitle(session.title(for: filters))
        .navigationSubtitle(subtitle)
        .searchable(text: $filters.text, placement: .toolbar, prompt: "Search, JQL, or paste a Jira link")
        .searchFocused($searchFocused)
        .searchSuggestions {
            ForEach(suggestions, id: \.completion) { s in
                Text(s.display).searchCompletion(s.completion)
            }
        }
        .onSubmit(of: .search) {
            if let url = URL(string: filters.text), url.scheme?.hasPrefix("http") == true, Session.issueKey(in: url) != nil {
                session.open(url: url)
                filters.text = ""
                return
            }
            session.recordSearch(filters.text)
        }
        .toolbar(id: "list") {
            NewIssueToolbarItem()
            ToolbarItem(id: "board") {
                if let b = boardTarget {
                    Button { openWindow(id: "board", value: b) } label: { Label("Board", systemImage: "rectangle.split.3x1") }
                        .help("Open the project board (⌘⇧B)")
                }
            }
            ToolbarItem(id: "saveFilter") {
                Button { filterName = ""; savingFilter = true } label: { Label("Save Filter", systemImage: "bookmark") }
                    .help("Keep these filters and search in the sidebar (⌘S)")
                    .disabled(!canSaveFilter)
            }
        }
        .alert("Save Filter", isPresented: $savingFilter) {
            TextField("Filter name", text: $filterName)
            Button("Save") { session.addPreset(name: filterName.trimmingCharacters(in: .whitespaces), filters: filters) }
                .disabled(filterName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current chips, search and sort order, under \(filters.account.flatMap(session.state)?.title ?? String(localized: "All Accounts")) in the sidebar.")
        }
        .task(id: loadKey) {
            // Debounce typing; JQL is evaluated server-side.
            if !filters.text.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            await store.load(filters, session: session)
        }
        .task(id: filters.text) { await updateSuggestions() }
        .task {
            // ponytail: a fixed 3-minute reload; a per-list "updated since" poll would be lighter if it ever matters.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(180))
                refreshTick += 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshTick += 1 }
        .onChange(of: filters) { old, new in
            if new.text.isEmpty, old.text.isEmpty, old != new { searchFocused = false }
        }
        .onChange(of: session.focusSearchRequested) { _, on in
            if on { searchFocused = true; session.focusSearchRequested = false }
        }
        .errorAlert($store.error)
    }

    /// → unfolds the selected parent's subtasks, ← folds them, as in an outline (the other way round right to left).
    private func fold(open: Bool) -> KeyPress.Result {
        guard let sel = selection, let d = displayRows.first(where: { $0.row.target == sel }), !d.children.isEmpty,
              expanded.contains(d.id) != open else { return .ignored }
        withAnimation(.snappy(duration: 0.25)) { expanded.formSymmetricDifference([d.id]) }
        return .handled
    }

    /// There is something to save once the list differs from every sidebar entry, built-in, saved or project.
    private var canSaveFilter: Bool {
        guard filters.isActive else { return false }
        if !filters.text.isEmpty { return true }
        var projectRow = ListFilters(); projectRow.account = filters.account; projectRow.project = filters.project
        return session.preset(matching: filters) == nil && filters != projectRow
    }

    private var boardTarget: BoardTarget? {
        guard let id = filters.account, let key = filters.project else { return nil }
        return BoardTarget(accountID: id, projectKey: key)
    }

    private var subtitle: String {
        guard !store.rows.isEmpty else { return "" }
        return issues(store.rows.count, more: store.nextToken != nil)
    }

    // MARK: Row actions

    @ViewBuilder
    private func rowMenu(_ row: ListRow) -> some View {
        IssueMenu(issue: row.issue, state: row.state, write: act)
    }

    /// Runs a write, then reloads the list and the open issue so both show the result.
    private func act(_ op: @escaping () async throws -> Void) {
        Task {
            do { try await op(); session.reloadTick += 1 } catch { store.error = error.localizedDescription }
        }
    }

    // MARK: Chips

    private func setAccount(_ id: UUID?) {
        filters.account = id
        // Projects, favourite filters and issue types belong to one site.
        filters.project = nil
        filters.jiraFilter = nil
        filters.type = nil
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if session.states.count > 1 {
                        FilterChip(id: "account", title: filters.account.flatMap(session.state)?.title ?? String(localized: "All accounts"), active: filters.account != nil, menus: chipMenus,
                                   items: [ChipItem(String(localized: "All accounts"), selected: filters.account == nil) { setAccount(nil) }, .separator]
                                       + session.states.map { st in ChipItem(st.title, selected: filters.account == st.id) { setAccount(st.id) } })
                    }
                    if let st = filters.account.flatMap(session.state) {
                        let projects = st.starredProjects + st.projects.filter { !st.starred.contains($0.key) }
                        FilterChip(id: "project", title: projects.first { $0.key == filters.project }?.name ?? filters.project ?? String(localized: "Any project"), active: filters.project != nil, menus: chipMenus,
                                   items: [ChipItem(String(localized: "Any project"), selected: filters.project == nil) { filters.project = nil }, .separator]
                                       + projects.map { p in ChipItem(p.name, selected: filters.project == p.key) { filters.project = p.key } })
                    }
                    if let f = filters.jiraFilter {
                        FilterChip(id: "jiraFilter", title: f.name, active: true, menus: chipMenus,
                                   items: [ChipItem(String(localized: "Clear filter"), selected: false) { filters.jiraFilter = nil }])
                    }
                    FilterChip(id: "scope", title: filters.scope.title, active: filters.scope != .all, menus: chipMenus,
                               items: ListFilters.Scope.allCases.map { s in ChipItem(s.title, selected: filters.scope == s) { filters.scope = s } })
                    FilterChip(id: "status", title: filters.status.title, active: filters.status != .any, menus: chipMenus,
                               items: ListFilters.Status.allCases.map { s in ChipItem(s.title, selected: filters.status == s) { filters.status = s } })
                    FilterChip(id: "assignee", title: filters.assignee.title, active: filters.assignee != .any, menus: chipMenus,
                               items: ListFilters.Assignee.allCases.map { a in ChipItem(a.title, selected: filters.assignee == a) { filters.assignee = a } })
                    FilterChip(id: "reporter", title: filters.reporter.title, active: filters.reporter != .any, menus: chipMenus,
                               items: ListFilters.Reporter.allCases.map { r in ChipItem(r.title, selected: filters.reporter == r) { filters.reporter = r } })
                    if let st = filters.account.flatMap(session.state) { // issue types differ per site, so the chip only makes sense inside one account
                        FilterChip(id: "type", title: filters.type ?? String(localized: "Any type"), active: filters.type != nil, menus: chipMenus,
                                   items: [ChipItem(String(localized: "Any type"), selected: filters.type == nil) { filters.type = nil }, .separator]
                                       + st.issueTypeNames.map { t in ChipItem(t, selected: filters.type == t) { filters.type = t } })
                    }
                    FilterChip(id: "updated", title: filters.updated.title, active: filters.updated != .any, menus: chipMenus,
                               items: ListFilters.Updated.allCases.map { u in ChipItem(u.title, selected: filters.updated == u) { filters.updated = u } })
                    if filters != cleared {
                        Button { filters = cleared } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).help("Clear filters")
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            FilterChip(id: "sort", title: filters.sort.field.title, symbol: filters.sort.descending ? "arrow.down" : "arrow.up", active: false, menus: chipMenus,
                       items: ListFilters.Sort.Field.allCases.map { f in ChipItem(f.title, selected: filters.sort.field == f) { filters.sort.field = f } }
                           + [.separator,
                              ChipItem(String(localized: "Ascending"), selected: !filters.sort.descending) { filters.sort.descending = false },
                              ChipItem(String(localized: "Descending"), selected: filters.sort.descending) { filters.sort.descending = true }])
                .help("Sort order")
                .padding(.trailing, 10)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .disabled(filters.isRawJQL || filters.isKey)
        .opacity(filters.isRawJQL || filters.isKey ? 0.4 : 1)
        .help(filters.isRawJQL ? "Filters don't apply to raw JQL" : filters.isKey ? "A key opens that issue whatever the filters" : "")
    }

    // MARK: Search assist

    private func updateSuggestions() async {
        let q = filters.text
        if q.isEmpty {
            suggestions = session.recentSearches.map { ($0, $0) }
            return
        }
        let fields = state?.jqlFields ?? []
        guard filters.isRawJQL || fields.contains(where: { q.lowercased().hasPrefix($0.value.lowercased()) }) else { suggestions = []; return }
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
}

/// The account tag on a row in a unified list: square, as opposed to the status capsule. Reads the
/// prominence itself, like StatusPill: the row's own read did not flip to white on a focused selection.
struct SiteBadge: View {
    let name: String
    let color: Color
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let tint: Color = prominence == .increased ? .white : color
        Text(name).font(.caption2.weight(.semibold)).foregroundStyle(tint)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(tint.opacity(prominence == .increased ? 0.28 : 0.16), in: .rect(cornerRadius: 4))
    }
}

struct IssueRow: View {
    let issue: Issue
    var site: (name: String, color: Color)?
    /// 1 for a subtask drawn under its parent.
    var depth = 0
    /// Subtasks folded under this row; a chevron shows when there are any.
    var folded = 0
    var expanded = false
    var toggle: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RemoteImage(url: issue.fields.issuetype.iconUrl, placeholder: "circle")
                .frame(width: 16, height: 16)
                .padding(.top, 2)
                .help(issue.fields.issuetype.name)
            VStack(alignment: .leading, spacing: 5) {
                if depth == 0, issue.fields.issuetype.isSubtask, let parent = issue.fields.parent {
                    // The parent is not in this list, so say which one it is.
                    Label { Text(verbatim: "\(parent.key)  \(parent.fields.summary)") } icon: { Image(systemName: "arrow.turn.down.right").flipsForRightToLeftLayoutDirection(true) }
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(alignment: .top, spacing: 6) {
                    Text(issue.fields.summary).lineLimit(2).strikethrough(issue.isDone).foregroundStyle(issue.isDone ? .secondary : .primary)
                    if let toggle {
                        Spacer(minLength: 0)
                        Button(action: toggle) {
                            Label(expanded ? "Hide subtasks" : "Show subtasks", systemImage: expanded ? "chevron.down" : "chevron.forward")
                                .labelStyle(.iconOnly)
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 22, height: 22).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help(expanded ? "Hide subtasks" : "Show \(folded) subtasks from this list")
                    }
                }
                HStack(spacing: 8) {
                    Text(issue.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if let site { SiteBadge(name: site.name, color: site.color) }
                    StatusPill(status: issue.fields.status)
                    if let p = issue.subtaskProgress {
                        Label("\(p.done) of \(p.total) done", systemImage: "checklist")
                            .font(.caption).foregroundStyle(p.done == p.total ? .green : .secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let p = issue.fields.priority { PriorityIcon(priority: p) }
                    Avatar(user: issue.fields.assignee, size: 18)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, CGFloat(depth) * 24)
        // The separator runs from the summary to the row's end on every row; a row with a chevron button would
        // otherwise get its own, shorter guess.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 26 + CGFloat(depth) * 24 }
        .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
    }
}

/// The right-click menu for an issue anywhere: list rows and board cards share it.
struct IssueMenu: View {
    let issue: Issue
    let state: AccountState
    /// Runs a write and refreshes whatever the owner shows.
    var write: (@escaping () async throws -> Void) -> Void
    @Environment(Session.self) private var session
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let key = issue.key
        let target = IssueTarget(accountID: state.id, key: key)
        let url = state.client.browseURL(key)
        let watching = issue.fields.watches?.isWatching == true
        let me = state.me?.accountId
        Button("Open in New Window", systemImage: "macwindow.badge.plus") { openWindow(id: "issue", value: target) }
        Button("Open in Browser", systemImage: "safari") { NSWorkspace.shared.open(url) }
        Divider()
        Button("Copy Link", systemImage: "link") { copyToPasteboard(url.absoluteString) }
        Button("Copy Key", systemImage: "number") { copyToPasteboard(key) }
        Button("Copy as Markdown", systemImage: "text.quote") { copyToPasteboard(state.client.markdownLink(key, summary: issue.fields.summary)) }
        ShareLink(item: url)
        Divider()
        Button(watching ? "Stop Watching This Issue" : "Watch This Issue", systemImage: watching ? "eye.slash" : "eye") {
            write { try await state.client.watch(key, !watching, me: me) }
        }
        Divider()
        // From the account's cache: a menu's content is fixed once open, so nothing can load inside it.
        if let transitions = state.transitionsByWorkflow[AccountState.workflowKey(issue)] {
            Menu("Change Status") {
                ForEach(transitions) { t in
                    Toggle(isOn: Binding(get: { t.to.id == issue.fields.status.id }, set: { on in if on { write { try await state.client.transition(key, to: t.id) } } })) { Text(t.name) }
                }
            }
        } else {
            Button("Change Status…") { openWindow(id: "issue", value: target); state.warmTransitions([issue]) }
        }
        if let me, issue.fields.assignee?.accountId != me {
            Button("Assign to Me", systemImage: "person.crop.circle.badge.checkmark") {
                write { try await state.client.assign(key, to: me) }
            }
        }
        if issue.fields.assignee != nil {
            Button("Unassign", systemImage: "person.crop.circle.badge.minus") {
                write { try await state.client.assign(key, to: nil) }
            }
        }
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
        // Under the chip's leading edge: a right-to-left menu hangs from the point by its top-right corner.
        let rtl = menu.userInterfaceLayoutDirection == .rightToLeft
        menu.popUp(positioning: nil, at: NSPoint(x: rtl ? anchor.bounds.width : 0, y: -4), in: anchor)
    }

    @objc private func fire(_ sender: NSMenuItem) { actions[sender]?() }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        Task { @MainActor in
            let closed = self.openID
            self.openID = nil
            let mouse = NSEvent.mouseLocation
            for (id, view) in self.anchors where id != closed {
                guard let window = view.window, let content = window.contentView else { continue }
                let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
                guard frame.contains(mouse) else { continue }
                // A chip scrolled under the sort chip, or the trailing edge of the chip strip, must not count.
                let local = content.convert(window.convertPoint(fromScreen: mouse), from: nil)
                guard let hit = content.hitTest(local), hit.isDescendant(of: view) || view.isDescendant(of: hit) else { continue }
                self.open(id); return
            }
        }
    }
}

struct FilterChip: View {
    let id: String
    let title: String
    var symbol: String?
    let active: Bool
    let menus: ChipMenuController
    let items: [ChipItem]

    var body: some View {
        Button { menus.toggle(id) } label: {
            HStack(spacing: 3) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
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
