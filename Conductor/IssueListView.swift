import AppKit
import SwiftUI

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
            if r.issue.fields.issuetype.isSubtask, let p = r.issue.fields.parent?.key,
                present.contains("\(r.state.id)|\(p)")
            {
                children["\(r.state.id)|\(p)", default: []].append(r)
            } else {
                top.append(r)
            }
        }
        // Sorted by update, a parent whose children were touched more recently moves with them; any other
        // order is the server's and stays as it came.
        if sort.field == .updated {
            func latest(_ r: ListRow) -> Date {
                max(
                    r.issue.fields.updated ?? .distantPast,
                    children[r.id]?.compactMap(\.issue.fields.updated).max() ?? .distantPast)
            }
            top.sort { a, b in
                let (la, lb) = (latest(a), latest(b))
                return la != lb ? (sort.descending ? la > lb : la < lb) : a.id < b.id
            }
        }
        // Jira lists undated issues first under "duedate DESC"; here the dated ones come first either way.
        if sort.field == .due {
            top = top.filter { $0.issue.fields.duedate != nil } + top.filter { $0.issue.fields.duedate == nil }
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
    /// How many issues the query matches on the server, every account summed: the last count from the cache until
    /// this load's own answers. Nil when no count is known yet.
    var total: Int?
    /// The subtitle's number: the rows once the whole list is loaded, else the server's count.
    var count: Int { single != nil && nextToken == nil && !isLoading ? rows.count : max(total ?? 0, rows.count) }
    /// True from the start: a new list is always about to load, and must not flash "No issues" first.
    var isLoading = true
    var error: String?
    /// The filters restrict nothing, which Jira refuses; the list explains instead of asking.
    var unbounded = false
    /// Jira rejected a typed query (half-written JQL, usually). Shown in the list, never as an alert.
    var queryError: String?
    private var generation = 0
    private var single: (AccountState, String, Bool)?
    /// The query whose rows (cached or fresh) are on screen.
    private var shownKey = ""
    private var shown = ListFilters()
    private var sort = ListFilters.Sort()

    /// One page of a query for one account. With `cache` on, the page is saved to disk, indexed for
    /// Spotlight and remembered as a peek for the issue page. Shared by the list and the launch prefetch.
    static func fetch(jql: String, state: AccountState, nextPageToken: String? = nil, cache: Bool) async throws
        -> SearchPage
    {
        let page = try await state.client.search(jql: jql, nextPageToken: nextPageToken)
        for issue in page.issues
        where
            !(state.peek[issue.key].map { $0.fields.updated == issue.fields.updated && $0.fields.comment != nil }
            ?? false)
        {
            state.peek[issue.key] = issue  // keep a full copy of the same revision; a row has fewer fields
        }
        state.warmTransitions(page.issues)
        if cache {
            if nextPageToken == nil {
                let name = "list-" + DiskCache.hash(jql)
                state.lists[name] = page.issues
                DiskCache.saveAsync(page.issues, account: state.account, name: name)
            }
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
            Task { @MainActor in await st.fetchDetails(group.map(\.issue.key)) }
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
        if unbounded {
            rows = []
            total = nil
            shownKey = ""
            shown = f
            isLoading = false
            return
        }
        let states = f.account.map { id in session.states.filter { $0.id == id } } ?? session.states
        let queries: [(AccountState, String)] = states.map { ($0, f.jql) }
        // Typed searches are not cached: they change with every keystroke and would litter the disk.
        let cacheable = f.text.isEmpty
        total = queries.reduce(0 as Int?) { sum, q in
            guard let sum, let c = q.0.listCounts["list-" + DiskCache.hash(q.1)] else { return nil }
            return sum + c
        }
        Task { await countIssues(queries, gen: gen, cache: cacheable) }
        let queryKey = queries.map { "\($0.0.id)|\($0.1)" }.joined()
        // Each account's rows stay put (from cache on a new query, else what is shown) until its own fresh
        // page lands, so the list never collapses to the fastest site and then grows back.
        var byAccount: [UUID: [ListRow]] = Dictionary(grouping: rows, by: \.state.id)
        if shownKey != queryKey {
            var resorted = shown
            resorted.sort = f.sort
            if resorted == f, !rows.isEmpty {
                // Only the order changed: the same rows change places at once, nothing is fetched to draw them.
                // The server's page lands behind (on a list longer than a page its first page can differ).
                byAccount = byAccount.mapValues { $0.sorted { f.sort.areInOrder($0.issue, $1.issue) } }
            } else {
                byAccount = cacheable ? await Self.cachedRows(queries) : [:]
                guard gen == generation else { return }
            }
            show(merged(byAccount))
            // Only now: a load superseded before its rows reached the screen must not let the next one skip them.
            shownKey = queryKey
        }
        shown = f
        isLoading = true
        if f.account == nil {
            let tasks = queries.map { st, jql in
                (
                    st.id,
                    Task<[ListRow]?, Never> { @MainActor in
                        guard let page = try? await Self.fetch(jql: jql, state: st, cache: cacheable) else {
                            return nil
                        }
                        return page.issues.map { ListRow(issue: $0, state: st) }
                    }
                )
            }
            for (id, t) in tasks {
                let fresh = await t.value
                guard gen == generation else { return }
                if let fresh { byAccount[id] = fresh }  // a failed site keeps what it had
                show(merged(byAccount))
            }
            isLoading = false
            if cacheable { Self.prefetchDetails(rows) }
        } else {
            guard let (st, jql) = queries.first else {
                rows = []
                isLoading = false
                return
            }
            single = (st, jql, cacheable)
            await fetchPage(gen: gen, replacing: true)
        }
    }

    /// One count request per account, in parallel with the page fetch; a failed site leaves the last count standing.
    private func countIssues(_ queries: [(AccountState, String)], gen: Int, cache: Bool) async {
        let tasks = queries.map { st, jql in Task { try? await st.client.approximateCount(jql: jql) } }
        var sum = 0
        for ((st, jql), t) in zip(queries, tasks) {
            guard let c = await t.value else { return }
            if cache {
                st.listCounts["list-" + DiskCache.hash(jql)] = c
                DiskCache.saveAsync(st.listCounts, account: st.account, name: "listCounts")
            }
            sum += c
        }
        if gen == generation { total = sum }
    }

    /// Last known first pages: from memory when this session has them (no suspension, so a list opened from the
    /// sidebar draws its rows in the same frame), else from disk, every account at once.
    private static func cachedRows(_ queries: [(AccountState, String)]) async -> [UUID: [ListRow]] {
        var out: [UUID: [ListRow]] = [:]
        var missing: [(AccountState, String)] = []
        for (st, jql) in queries {
            if let hit = st.lists["list-" + DiskCache.hash(jql)] {
                out[st.id] = hit.map { ListRow(issue: $0, state: st) }
            } else {
                missing.append((st, jql))
            }
        }
        guard !missing.isEmpty else { return out }
        let reads = missing.map { st, jql in
            let name = "list-" + DiskCache.hash(jql)
            return (
                st, name,
                Task.detached(priority: .userInitiated) { [account = st.account] in
                    DiskCache.load([Issue].self, account: account, name: name)
                }
            )
        }
        for (st, name, read) in reads {
            guard let issues = await read.value else { continue }
            st.lists[name] = issues
            out[st.id] = issues.map { ListRow(issue: $0, state: st) }
        }
        return out
    }

    /// Replaces the rows unless nothing changed: a refresh that brings the same page back must not redraw the list.
    private func show(_ new: [ListRow]) {
        guard new.count != rows.count || zip(new, rows).contains(where: { $0.id != $1.id || $0.issue != $1.issue })
        else { return }
        rows = new
    }

    private func merged(_ byAccount: [UUID: [ListRow]]) -> [ListRow] {
        byAccount.count == 1
            ? byAccount.values.first! : byAccount.values.flatMap { $0 }.sorted { sort.areInOrder($0.issue, $1.issue) }
    }

    func loadMore() async {
        guard nextToken != nil, !isLoading, single != nil else { return }
        await fetchPage(gen: generation, replacing: false)
    }

    private func fetchPage(gen: Int, replacing: Bool) async {
        guard let (st, jql, cacheable) = single else { return }
        isLoading = true
        // Not for a superseded page: the load that replaced it is still running under the same flag.
        defer { if gen == generation { isLoading = false } }
        do {
            let page = try await Self.fetch(jql: jql, state: st, nextPageToken: nextToken, cache: cacheable)
            guard gen == generation else { return }
            let fresh = page.issues.map { ListRow(issue: $0, state: st) }
            if replacing { show(fresh) } else { rows += fresh }
            nextToken = page.isLast == true ? nil : page.nextPageToken
            if replacing, cacheable { Self.prefetchDetails(rows) }
        } catch {
            guard gen == generation, !error.isOffline, !error.isCancelled else { return }
            // A 400 on a typed search is the query itself; an alert would steal the keystrokes that fix it.
            if !cacheable, (error as? JiraError)?.status == 400 {
                queryError = error.localizedDescription
                rows = []
            } else {
                self.error = error.localizedDescription
            }
        }
    }
}

struct IssueListView: View {
    @Binding var filters: ListFilters
    /// The previewed issue; the main window owns it so Escape can clear it from anywhere.
    @Binding var selection: IssueTarget?
    /// The toolbar title item's width, for the main window to size the column by.
    @Binding var titleWidth: CGFloat
    @Environment(Session.self) private var session
    @Environment(\.openWindow) private var openWindow
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.appearsActive) private var active
    @State private var store = IssueListStore()
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
    /// The last count shown, kept on screen while a new list has nothing yet.
    @State private var shownSubtitle = ""
    private var loadKey: String { "\(filters)|\(session.reloadTick)|\(session.listTick)|\(refreshTick)" }
    /// What the clear button goes back to: the sidebar entry the list came from, or the bare project; the search
    /// and the sort order stay. It shows only once the chips differ from that.
    private var cleared: ListFilters {
        var f = session.preset(matching: filters)?.filters ?? ListFilters()
        f.account = filters.account
        f.project = filters.project
        f.text = filters.text
        f.sort = filters.sort
        return f
    }

    var body: some View {
        let shown = displayRows
        List(selection: $selection) {
            ForEach(shown) { d in
                let row = d.row
                // The open issue stays in the accent colour while the window is active, as in Notes and Mail;
                // behind another window it goes grey like any selection.
                let selected = selection == row.target
                let emphasized = selected && active
                IssueRow(
                    issue: row.issue,
                    site: isUnified && session.states.count > 1 ? (row.state.title, row.state.color) : nil,
                    date: filters.sort.date(of: row.issue), dayOnly: filters.sort.field == .due,
                    depth: d.depth, folded: d.children.count, expanded: expanded.contains(d.id),
                    toggle: d.children.isEmpty
                        ? nil : { withAnimation(.snappy(duration: 0.25)) { expanded.formSymmetricDifference([d.id]) } }
                )
                .id(row.issue.fields.summary)  // a new view after an edit, so the table measures the row again
                .tag(row.target)
                // The table's own highlight, grey without focus, is off: the rows paint theirs.
                .foregroundStyle(emphasized ? AnyShapeStyle(.white) : AnyShapeStyle(.foreground))
                .environment(\.backgroundProminence, emphasized ? .increased : .standard)
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            emphasized
                                ? Color.accentColor
                                : selected ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear
                        )
                        .padding(.horizontal, 8)
                )
                .onAppear { if d.id == shown.last?.id { Task { await store.loadMore() } } }
                // Drag a row into Slack, a browser or a note as its Jira link.
                .itemProvider {
                    let p = NSItemProvider(object: row.state.client.browseURL(row.issue.key) as NSURL)
                    p.suggestedName = "\(row.issue.key) \(row.issue.fields.summary)"  // the .webloc's name in the Finder
                    return p
                }
            }
            // Only while there is nothing to show or the next page is coming: a refresh behind rows that are
            // already on screen must not add and remove a row at the end of the list.
            if store.isLoading, store.rows.isEmpty || store.nextToken != nil {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .listRowSeparator(.hidden)
            }
            if filters.scope == .recent, !store.rows.isEmpty, !store.isLoading {
                // Jira's history only records issues opened on the web; nothing Conductor does can add to it.
                Text(
                    "Jira keeps this list from the issues you open on the web. Issues opened in Conductor don't count."
                )
                .font(.caption).foregroundStyle(.tertiary).padding(.vertical, 8)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .background(NativeSelectionOff())
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
                ContentUnavailableView(
                    "Pick a filter", systemImage: "line.3.horizontal.decrease.circle",
                    description: Text(
                        "Jira won't list a whole site at once. Choose a project, a status, a person or a scope, or type a search."
                    ))
            } else if let e = store.queryError {
                ContentUnavailableView("Incomplete query", systemImage: "text.magnifyingglass", description: Text(e))
            } else if !store.isLoading, store.rows.isEmpty {
                ContentUnavailableView {
                    Label(filters.isActive ? "No matches" : "No issues", systemImage: "tray")
                } description: {
                    if filters != cleared { Text("Nothing matches these filters.") }
                } actions: {
                    if !filters.text.isEmpty {
                        Button("Clear Search") { filters.text = "" }
                    } else if filters != cleared {
                        Button("Clear Filters") { filters = cleared }
                    }
                }
            }
        }
        .focusedSceneValue(
            \.listActions,
            ListActions(
                saveFilter: canSaveFilter
                    ? {
                        filterName = ""
                        savingFilter = true
                    } : nil,
                openBoard: boardTarget.map { b in { openWindow(id: "board", value: b) } },
                sort: $filters.sort
            )
        )
        .navigationTitle(session.title(for: filters))  // the Window menu; the toolbar draws its own, with the sort
        .toolbar(removing: .title)
        .background(ToolbarRelayout())
        .searchable(text: $filters.text, placement: .toolbar, prompt: "Search, JQL, or paste a Jira link")
        .searchFocused($searchFocused)
        .searchSuggestions {
            // With nothing typed the list is the recent searches, and says so. Nothing at all (not even an
            // empty section) when there is nothing to offer, or an empty panel hangs under the field.
            if !suggestions.isEmpty {
                if filters.text.isEmpty {
                    Section("Recent Searches") { suggestionRows }
                } else {
                    suggestionRows
                }
            }
        }
        .onSubmit(of: .search) {
            if let url = URL(string: filters.text), url.scheme?.hasPrefix("http") == true,
                Session.issueKey(in: url) != nil
            {
                session.open(url: url)
                filters.text = ""
                searchFocused = false  // or the recent-searches panel stays under the field
                return
            }
            // A key opens its issue at once: the list shows the row and the preview shows the page.
            if filters.isKey {
                let key = filters.text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if let st = filters.account.flatMap(session.state) ?? session.state(forKey: key) {
                    selection = IssueTarget(accountID: st.id, key: key)
                    searchFocused = false
                }
                return
            }
            session.recordSearch(filters.text)
        }
        .toolbar(id: "list") {
            ToolbarItem(id: "title") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title(for: filters)).font(.headline)
                    HStack(spacing: 4) {
                        if !shownSubtitle.isEmpty { Text(verbatim: "\(shownSubtitle) ·") }
                        Menu {
                            SortMenuItems(sort: $filters.sort)
                        } label: {
                            HStack(spacing: 2) {
                                Text("sorted by \(filters.sort.field.headerTitle)")
                                Image(systemName: filters.sort.descending ? "arrow.down" : "arrow.up")
                                    .font(.caption2.weight(.bold))
                            }
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                        .help("Sort order")
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: true, vertical: false)  // never "47 issue…": the toolbar fits around it
                .padding(.leading, 14)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: {
                    titleWidth = $0
                }
            }
            .glassTitle()
            ToolbarItem(id: "new") {
                Button {
                    session.createIssueRequested = true
                } label: {
                    Label("New Issue", systemImage: "square.and.pencil")
                }
                .help("New issue (⌘N)")
            }
            ToolbarItem(id: "board") {
                if let b = boardTarget {
                    Button {
                        openWindow(id: "board", value: b)
                    } label: {
                        Label("Board", systemImage: "rectangle.split.3x1")
                    }
                    .help("Open the project board (⌘⇧B)")
                }
            }
            ToolbarItem(id: "saveFilter") {
                Button {
                    filterName = ""
                    savingFilter = true
                } label: {
                    Label("Save Filter", systemImage: "bookmark")
                }
                .help("Keep these filters and search in the sidebar (⌘S)")
                .disabled(!canSaveFilter)
            }
        }
        .alert("Save Filter", isPresented: $savingFilter) {
            TextField("Filter name", text: $filterName)
            Button("Save") {
                session.addPreset(name: filterName.trimmingCharacters(in: .whitespaces), filters: filters)
            }
            .disabled(filterName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The current chips, search and sort order, under \(filters.account.flatMap(session.state)?.title ?? String(localized: "All Accounts")) in the sidebar."
            )
        }
        .task(id: loadKey) {
            // Debounce typing; JQL is evaluated server-side.
            if !filters.text.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            await store.load(filters, session: session)
        }
        .task(id: filters.text) { await updateSuggestions() }
        .onChange(of: subtitle, initial: true) { if let s = subtitle { shownSubtitle = s } }
        .task {
            // ponytail: a fixed 3-minute reload; a per-list "updated since" poll would be lighter if it ever matters.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(180))
                refresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        .onChange(of: filters) { old, new in
            if new.text.isEmpty, old.text.isEmpty, old != new { searchFocused = false }
        }
        .onChange(of: session.focusSearchRequested) { _, on in
            if on {
                searchFocused = true
                session.focusSearchRequested = false
            }
        }
        // A click on a row selects it but leaves the keyboard where it was (the search field, or nowhere);
        // as in Mail, the list takes it. A row picked with the arrows already has it.
        .onChange(of: selection) { _, new in
            guard new != nil else { return }
            searchFocused = false  // or SwiftUI hands the keyboard straight back to the search field
            NSApp.keyWindow?.focusList()
        }
        // ↓ in the search field goes on to the results, as in Spotlight, unless completions are showing.
        .background(
            WindowEventMonitor(mask: .keyDown) { e in
                // Arrows carry the function and numeric-pad flags, so only the real modifiers count.
                guard e.keyCode == 125, e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                    let tv = e.window?.firstResponder as? NSTextView, tv.isFieldEditor, tv.delegate is NSSearchField,
                    suggestions.isEmpty, !shown.isEmpty
                else { return e }
                if selection == nil { selection = shown.first?.row.target }
                searchFocused = false
                NSApp.keyWindow?.focusList()
                return nil
            }
        )
        .errorAlert($store.error)
    }

    private var suggestionRows: some View {
        ForEach(suggestions, id: \.completion) { s in Text(s.display).searchCompletion(s.completion) }
    }

    /// A load already in flight is as fresh as a new one would be; restarting it (the app activating at launch
    /// did) would only throw its answer away.
    private func refresh() { if !store.isLoading { refreshTick += 1 } }

    /// → unfolds the selected parent's subtasks, ← folds them, as in an outline (the other way round right to left).
    private func fold(open: Bool) -> KeyPress.Result {
        guard let sel = selection, let d = displayRows.first(where: { $0.row.target == sel }), !d.children.isEmpty,
            expanded.contains(d.id) != open
        else { return .ignored }
        withAnimation(.snappy(duration: 0.25)) { expanded.formSymmetricDifference([d.id]) }
        return .handled
    }

    /// There is something to save once the list differs from every sidebar entry, built-in, saved or project.
    private var canSaveFilter: Bool {
        guard filters.isActive else { return false }
        if !filters.text.isEmpty { return true }
        var projectRow = ListFilters()
        projectRow.account = filters.account
        projectRow.project = filters.project
        return session.preset(matching: filters) == nil && filters != projectRow
    }

    private var boardTarget: BoardTarget? {
        guard let id = filters.account, let key = filters.project else { return nil }
        return BoardTarget(accountID: id, projectKey: key)
    }

    /// The issues the query matches (the server's count, or the rows once all are loaded); "50+" only while no
    /// count is known. Nil while a list loads with nothing to show yet.
    private var subtitle: String? {
        store.rows.isEmpty && store.total == nil && store.isLoading
            ? nil : issues(store.count, more: store.total == nil && store.nextToken != nil)
    }

    // MARK: Row actions

    @ViewBuilder
    private func rowMenu(_ row: ListRow) -> some View {
        IssueMenu(issue: row.issue, state: row.state, write: act)
    }

    /// Runs a write, then reloads the list and the open issue so both show the result.
    private func act(_ op: @escaping () async throws -> Void) {
        Task {
            do {
                try await op()
                session.reloadTick += 1
            } catch { store.error = error.localizedDescription }
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

    /// One filter: its chip, shown while the filter is set, and its submenu under the Filter chip while it is not.
    private struct Chip {
        let id: String
        let name: String
        let title: String
        let active: Bool
        let items: [ChipItem]
    }

    private var chipList: [Chip] {
        var list: [Chip] = []
        if session.states.count > 1 {
            list.append(
                Chip(
                    id: "account", name: String(localized: "Account"),
                    title: filters.account.flatMap(session.state)?.title ?? String(localized: "All accounts"),
                    active: filters.account != nil,
                    items: [
                        ChipItem(String(localized: "All accounts"), selected: filters.account == nil) {
                            setAccount(nil)
                        }, .separator,
                    ]
                        + session.states.map { st in
                            ChipItem(st.title, selected: filters.account == st.id) { setAccount(st.id) }
                        }))
        }
        if let st = filters.account.flatMap(session.state) {
            let projects = st.starredProjects + st.projects.filter { !st.starred.contains($0.key) }
            list.append(
                Chip(
                    id: "project", name: String(localized: "Project"),
                    title: projects.first { $0.key == filters.project }?.name ?? filters.project
                        ?? String(localized: "Any project"), active: filters.project != nil,
                    items: [
                        ChipItem(String(localized: "Any project"), selected: filters.project == nil) {
                            filters.project = nil
                        }, .separator,
                    ]
                        + projects.map { p in
                            ChipItem(p.name, selected: filters.project == p.key) { filters.project = p.key }
                        }))
        }
        if let f = filters.jiraFilter {
            list.append(
                Chip(
                    id: "jiraFilter", name: f.name, title: f.name, active: true,
                    items: [ChipItem(String(localized: "Clear filter"), selected: false) { filters.jiraFilter = nil }]))
        }
        list.append(
            Chip(
                id: "scope", name: String(localized: "Scope"), title: filters.scope.title,
                active: filters.scope != .all,
                items: ListFilters.Scope.allCases.map { s in
                    ChipItem(s.title, selected: filters.scope == s) { filters.scope = s }
                }))
        list.append(
            Chip(
                id: "status", name: String(localized: "Status"), title: filters.status.title,
                active: filters.status != .any,
                items: ListFilters.Status.allCases.map { s in
                    ChipItem(s.title, selected: filters.status == s) { filters.status = s }
                }))
        list.append(
            Chip(
                id: "assignee", name: String(localized: "Assignee"), title: filters.assignee.title,
                active: filters.assignee != .any,
                items: ListFilters.Assignee.allCases.map { a in
                    ChipItem(a.title, selected: filters.assignee == a) { filters.assignee = a }
                }))
        list.append(
            Chip(
                id: "reporter", name: String(localized: "Reporter"), title: filters.reporter.title,
                active: filters.reporter != .any,
                items: ListFilters.Reporter.allCases.map { r in
                    ChipItem(r.title, selected: filters.reporter == r) { filters.reporter = r }
                }))
        if let st = filters.account.flatMap(session.state) {  // issue types differ per site, so the chip only makes sense inside one account
            list.append(
                Chip(
                    id: "type", name: String(localized: "Type"), title: filters.type ?? String(localized: "Any type"),
                    active: filters.type != nil,
                    items: [
                        ChipItem(String(localized: "Any type"), selected: filters.type == nil) { filters.type = nil },
                        .separator,
                    ]
                        + st.issueTypeNames.map { t in ChipItem(t, selected: filters.type == t) { filters.type = t } }))
        }
        list.append(
            Chip(
                id: "updated", name: String(localized: "Updated"), title: filters.updated.title,
                active: filters.updated != .any,
                items: ListFilters.Updated.allCases.map { u in
                    ChipItem(u.title, selected: filters.updated == u) { filters.updated = u }
                }))
        return list
    }

    /// Only the filters that are set get a chip; the rest wait under one Filter chip, so the column stays narrow.
    private var chips: some View {
        let all = chipList
        let more = all.filter { !$0.active }
        // A key or raw JQL ignores the chips: they go grey like an inactive window's, still legible.
        let muted = filters.isRawJQL || filters.isKey
        return HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(all.filter(\.active), id: \.id) { c in
                        FilterChip(
                            id: c.id, title: c.title, active: true, enabled: !muted, menus: chipMenus, items: c.items)
                    }
                    if !more.isEmpty {
                        FilterChip(
                            id: "add", title: String(localized: "Filter"), symbol: "plus", active: false,
                            menus: chipMenus,
                            items: more.map { ChipItem($0.name, children: $0.items) }
                        )
                        .help("Add a filter")
                    }
                    if filters != cleared {
                        Button {
                            filters = cleared
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain).help("Clear filters")
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .disabled(muted)
        .help(
            filters.isRawJQL
                ? "Filters don't apply to raw JQL" : filters.isKey ? "A key opens that issue whatever the filters" : "")
    }

    // MARK: Search assist

    private func updateSuggestions() async {
        let q = filters.text
        if q.isEmpty {
            suggestions = session.recentSearches.map { ($0, $0) }
            return
        }
        // Issues the app has seen whose key or summary matches, newest first: picking one puts its key in the
        // field, and ↩ opens it. Raw JQL gets the field and value help below instead.
        if !filters.isRawJQL {
            let needle = q.trimmingCharacters(in: .whitespaces)
            var seen = Set<String>()
            let hits = session.states.flatMap(\.knownIssues)
                .filter {
                    seen.insert($0.key).inserted
                        && ($0.key.hasPrefix(needle.uppercased())
                            || $0.fields.summary.localizedCaseInsensitiveContains(needle))
                }
                .sorted { ($0.fields.updated ?? .distantPast) > ($1.fields.updated ?? .distantPast) }
                .prefix(5)
            if !hits.isEmpty {
                suggestions = hits.map { (display: "\($0.key)  \($0.fields.summary)", completion: $0.key) }
                return
            }
        }
        let fields = state?.jqlFields ?? []
        // A lone word of two letters or more that starts a field name ("sta") completes to it; a longer plain
        // search ("fix the login") is left alone.
        let startsField =
            q.count >= 2 && !q.contains(" ") && fields.contains { $0.value.lowercased().hasPrefix(q.lowercased()) }
        guard
            filters.isRawJQL || startsField
                || fields.contains(where: { q.lowercased().hasPrefix($0.value.lowercased()) })
        else {
            // Tuples are not Equatable, so SwiftUI cannot tell [] from []; a write here redraws the list per keystroke.
            if !suggestions.isEmpty { suggestions = [] }
            return
        }
        // "status = In" → values for status; "sta" → field names.
        if let m = q.firstMatch(
            of:
                /(.*?)([A-Za-z_][\w\[\]. ]*?)\s*(=|!=|~|!~|>=|<=|>|<|\bin\b|\bnot in\b|\bis not\b|\bis\b)\s*("?)([^"]*)$/
                .ignoresCase())
        {
            let field = String(m.2).trimmingCharacters(in: .whitespaces)
            let partial = String(m.5)
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let c = state?.client else { return }
            let values = (try? await c.jqlSuggestions(field: field, value: partial)) ?? []
            let prefix = String(m.1) + field + " " + String(m.3) + " "
            suggestions = values.prefix(8).map {
                (
                    $0.displayName.replacingOccurrences(of: "<b>", with: "").replacingOccurrences(of: "</b>", with: ""),
                    prefix + $0.value + " "
                )
            }
            return
        }
        guard let last = q.split(separator: " ", omittingEmptySubsequences: false).last else {
            if !suggestions.isEmpty { suggestions = [] }
            return
        }
        let head = q.dropLast(last.count)
        let word = last.lowercased()
        guard !word.isEmpty else {
            if !suggestions.isEmpty { suggestions = [] }
            return
        }
        suggestions =
            fields
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
        Text(name).font(.caption2.weight(.semibold)).foregroundStyle(tint).fixedSize()
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(tint.opacity(prominence == .increased ? 0.28 : 0.16), in: .rect(cornerRadius: 4))
            .inactiveDim()
    }
}

struct IssueRow: View {
    let issue: Issue
    var site: (name: String, color: Color)?
    /// On the summary line's trailing end, as Mail dates its rows: the date the list is sorted by.
    var date: Date?
    /// A due date is a calendar day; its tooltip shows no time.
    var dayOnly = false
    /// 1 for a subtask drawn under its parent.
    var depth = 0
    /// Subtasks folded under this row; a chevron shows when there are any.
    var folded = 0
    var expanded = false
    var toggle: (() -> Void)?
    /// `.increased` on the selected row: the accent is the background, so the greys go white and the icons
    /// get a light backing, like the priority icon.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let selected = prominence == .increased
        let dim: Color = selected ? .white.opacity(0.85) : .secondary
        HStack(alignment: .top, spacing: 10) {
            RemoteImage(url: issue.fields.issuetype.iconUrl, placeholder: "circle")
                .frame(width: 16, height: 16)
                .padding(2).background(selected ? .white.opacity(0.9) : .clear, in: .rect(cornerRadius: 5)).padding(-2)
                .padding(.top, 2)
                .inactiveDim()
                .help(issue.fields.issuetype.name)
            VStack(alignment: .leading, spacing: 5) {
                if depth == 0, issue.fields.issuetype.isSubtask, let parent = issue.fields.parent {
                    // The parent is not in this list, so say which one it is.
                    Label {
                        Text(verbatim: "\(parent.key)  \(parent.fields.summary)")
                    } icon: {
                        Image(systemName: "arrow.turn.down.right").flipsForRightToLeftLayoutDirection(true)
                    }
                    .font(.caption).foregroundStyle(dim).lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(issue.fields.summary).lineLimit(2).strikethrough(issue.isDone).foregroundStyle(
                        issue.isDone ? dim : selected ? .white : .primary)
                    Spacer(minLength: 0)
                    if let date {
                        Text(relativeDay(date)).font(.caption).foregroundStyle(dim).fixedSize()
                            .help(
                                dayOnly
                                    ? date.formatted(date: .long, time: .omitted)
                                    : date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                HStack(spacing: 8) {
                    // Key and status never wrap or truncate; the count is the first to give, down to "1/3".
                    Text(issue.key).font(.caption.monospaced()).foregroundStyle(dim).fixedSize()
                    if let site { SiteBadge(name: site.name, color: site.color) }
                    StatusPill(status: issue.fields.status).fixedSize()
                    if let p = issue.subtaskProgress {
                        ViewThatFits(in: .horizontal) {
                            Label("\(p.done) of \(p.total) done", systemImage: "checklist")
                            Label {
                                Text(verbatim: "\(p.done)/\(p.total)")
                            } icon: {
                                Image(systemName: "checklist")
                            }
                        }
                        .font(.caption).foregroundStyle(p.done == p.total && !selected ? .green : dim).lineLimit(1)
                        .layoutPriority(1)
                    }
                    if let toggle {
                        Button(action: toggle) {
                            Label(
                                expanded ? "Hide subtasks" : "Show subtasks",
                                systemImage: expanded ? "chevron.down" : "chevron.forward"
                            )
                            .labelStyle(.iconOnly)
                            .font(.caption.weight(.semibold)).foregroundStyle(dim).frame(width: 18, height: 18)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help(expanded ? "Hide subtasks" : "Show \(folded) subtasks from this list")
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
    var write: (@escaping @Sendable () async throws -> Void) -> Void
    @Environment(Session.self) private var session
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let key = issue.key
        let target = IssueTarget(accountID: state.id, key: key)
        let url = state.client.browseURL(key)
        let watching = issue.fields.watches?.isWatching == true
        let me = state.me?.accountId
        // The Issue menu's order.
        Button("Open in Browser", systemImage: "safari") { NSWorkspace.shared.open(url) }
        Button("Open in New Window", systemImage: "macwindow.badge.plus") { openWindow(id: "issue", value: target) }
        Divider()
        Button("Copy Link", systemImage: "link") { copyToPasteboard(url.absoluteString) }
        Button("Copy as Markdown", systemImage: "text.quote") {
            copyToPasteboard(state.client.markdownLink(key, summary: issue.fields.summary))
        }
        Button("Copy Key", systemImage: "number") { copyToPasteboard(key) }
        ShareLink(item: url)
        Divider()
        Button(watching ? "Stop Watching This Issue" : "Watch This Issue", systemImage: watching ? "eye.slash" : "eye")
        {
            write { try await state.client.watch(key, !watching, me: me) }
        }
        Divider()
        // From the account's cache: a menu's content is fixed once open, so nothing can load inside it.
        if let transitions = state.transitionsByWorkflow[AccountState.workflowKey(issue)] {
            Menu("Change Status") {
                ForEach(transitions) { t in
                    Toggle(
                        isOn: Binding(
                            get: { t.to.id == issue.fields.status.id },
                            set: { on in
                                guard on else { return }
                                let (old, account) = (issue.fields.status, state.id)
                                write {
                                    try await state.client.transition(key, to: t.id)
                                    await Bin.shared.put(.status(old), account: account, key: key)
                                }
                            })
                    ) { Text(t.name) }
                }
            }
        } else {
            Button("Change Status…") {
                openWindow(id: "issue", value: target)
                state.warmTransitions([issue])
            }
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
    /// A submenu instead of an action.
    var children: [ChipItem] = []
    init(_ title: String, selected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.selected = selected
        self.action = action
    }
    init(_ title: String, children: [ChipItem]) {
        self.title = title
        selected = false
        action = nil
        self.children = children
    }
    private init() {
        title = ""
        selected = false
        action = nil
    }
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
        if openID == id { return }  // the click that closed it must not reopen it
        open(id)
    }

    private func open(_ id: String) {
        guard let anchor = anchors[id], let list = items[id] else { return }
        actions = [:]
        let menu = build(list)
        menu.delegate = self
        menu.identifier = NSUserInterfaceItemIdentifier("chip")  // MenuClickThrough leaves these to menuDidClose
        openID = id
        // Under the chip's leading edge: a right-to-left menu hangs from the point by its top-right corner.
        let rtl = menu.userInterfaceLayoutDirection == .rightToLeft
        menu.popUp(positioning: nil, at: NSPoint(x: rtl ? anchor.bounds.width : 0, y: -4), in: anchor)
    }

    private func build(_ list: [ChipItem]) -> NSMenu {
        let menu = NSMenu()
        for item in list {
            if item.action == nil, item.children.isEmpty {
                menu.addItem(.separator())
                continue
            }
            let mi = NSMenuItem(
                title: item.title, action: item.action == nil ? nil : #selector(fire(_:)), keyEquivalent: "")
            mi.target = self
            mi.state = item.selected ? .on : .off
            if let action = item.action { actions[mi] = action } else { mi.submenu = build(item.children) }
            menu.addItem(mi)
        }
        return menu
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
                guard let hit = content.hitTest(local), hit.isDescendant(of: view) || view.isDescendant(of: hit) else {
                    continue
                }
                self.open(id)
                return
            }
        }
    }
}

struct FilterChip: View {
    let id: String
    let title: String
    var symbol: String?
    let active: Bool
    /// False while a key or raw JQL search ignores the chips: set, but not lit.
    var enabled = true
    let menus: ChipMenuController
    let items: [ChipItem]
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        // Behind another window, or ignored by a key search, a set chip goes grey with dark text, as Mail's selection does.
        let lit = active && appearsActive && enabled
        Button {
            menus.toggle(id)
        } label: {
            HStack(spacing: 3) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(lit ? Color.white : .primary)
            .background(
                lit
                    ? Color.accentColor
                    : active
                        ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : Color.primary.opacity(0.07),
                in: .capsule
            )
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .background(ChipAnchor(id: id, menus: menus, items: items))
    }
}

/// The sort order as menu items: the View menu and the toolbar's "sorted by" show the same.
struct SortMenuItems: View {
    @Binding var sort: ListFilters.Sort

    var body: some View {
        ForEach(ListFilters.Sort.Field.allCases, id: \.self) { f in
            Toggle(f.title, isOn: Binding(get: { sort.field == f }, set: { if $0 { sort.field = f } }))
        }
        Divider()
        Toggle("Ascending", isOn: Binding(get: { !sort.descending }, set: { if $0 { sort.descending = false } }))
        Toggle("Descending", isOn: Binding(get: { sort.descending }, set: { if $0 { sort.descending = true } }))
    }
}

/// Turns off the table's own selection drawing; the rows paint theirs. Behind the list rather than inside a
/// row: a platform view in a row put the first frame back by ~60 ms.
private struct NativeSelectionOff: NSViewRepresentable {
    func makeNSView(context: Context) -> Finder { Finder() }
    func updateNSView(_ view: Finder, context: Context) {}
    final class Finder: NSView {
        override func viewDidMoveToWindow() { find(attempt: 0) }

        /// The table is a sibling subtree: the nearest ancestor with one below it, short of the split view that
        /// also holds the sidebar's. It can arrive a turn after this view, hence the retries.
        private func find(attempt: Int) {
            guard window != nil else { return }
            var v = superview
            while let s = v, !(s is NSSplitView) {
                if let table = firstTable(in: s) {
                    table.selectionHighlightStyle = .none
                    table.allowsTypeSelect = false  // letters are shortcuts here, not a jump to a row
                    return
                }
                v = s.superview
            }
            if attempt < 10 { DispatchQueue.main.async { self.find(attempt: attempt + 1) } }
        }
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
