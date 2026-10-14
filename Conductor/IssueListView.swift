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
    /// Keys with a write on its way to Jira.
    var pending: Set<String> = []
    /// One account's share of the list: its rows so far and where its next page starts.
    private struct Page {
        let state: AccountState
        var rows: [ListRow]
        /// The part of the list (see `ListFilters.jqlParts`) the next page comes from, and the page's token.
        var part = 0
        var token: String?
        /// How many of `rows` this load fetched; the rest are the last load's, kept below them (see `fetchPage`).
        var fetched = 0
        /// More rows to load: a next page, or a part not started. A page not fetched yet (cached, or kept from the
        /// last load) is taken to have more when it is a full page, so the merge holds the same rows back.
        var more: Bool
        init(state: AccountState, rows: [ListRow], more: Bool? = nil) {
            (self.state, self.rows, self.more) = (state, rows, more ?? (rows.count >= 50))
        }
    }
    private var pages: [UUID: Page] = [:]
    private var query: (jql: String, parts: [String], cache: Bool)?
    var hasMore: Bool { pages.values.contains(where: \.more) }
    /// How many issues the query matches on the server, every account summed: the last count from the cache until
    /// this load's own answers. Nil when no count is known yet.
    var total: Int?
    /// The subtitle's number: the rows once the whole list is loaded, else the server's count.
    var count: Int { query != nil && !hasMore && !isLoading ? rows.count : max(total ?? 0, rows.count) }
    /// True from the start: a new list is always about to load, and must not flash "No issues" first.
    var isLoading = true
    /// The next page is on its way: the only load that shows a spinner under rows already on screen.
    var isLoadingMore = false
    var error: String?
    /// The filters restrict nothing, which Jira refuses; the list explains instead of asking.
    var unbounded = false
    /// Jira rejected a typed query (half-written JQL, usually). Shown in the list, never as an alert.
    var queryError: String?
    private var generation = 0
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
        for issue in page.issues { state.peek[issue.key] = issue }
        state.warmTransitions(page.issues)
        if cache {
            if nextPageToken == nil { remember(page.issues, jql: jql, state: state) }
            Spotlight.index(page.issues, host: state.host)
        }
        return page
    }

    /// A list's first page, kept in memory and on disk under its query for the next time it opens.
    static func remember(_ issues: [Issue], jql: String, state: AccountState) {
        let name = "list-" + DiskCache.hash(jql)
        state.lists[name] = issues
        DiskCache.saveAsync(issues, account: state.account, name: name)
    }

    /// One page's worth of a list made of parts: a part used up is followed at once by the next while the page is
    /// short, so the rows arrive together and nothing is added under them a moment later. The first page of a
    /// list of parts is cached whole, under the list's own query.
    static func pageWorth(
        _ parts: [String], whole jql: String, part: Int, token: String?, state: AccountState, cache: Bool
    ) async throws -> (issues: [Issue], part: Int, token: String?) {
        let first = part == 0 && token == nil
        var (issues, part, token) = ([Issue](), part, token)
        while true {
            // A part's own first page is not a list anyone opens: only the whole is cached, below.
            let page = try await fetch(
                jql: parts[part], state: state, nextPageToken: token, cache: cache && parts.count == 1)
            if cache, parts.count > 1 { Spotlight.index(page.issues, host: state.host) }
            issues += page.issues
            token = page.isLast == true ? nil : page.nextPageToken
            guard token == nil, part + 1 < parts.count else { break }
            part += 1
            if issues.count >= 50 { break }
        }
        if cache, parts.count > 1, first { remember(issues, jql: jql, state: state) }
        return (issues, part, token)
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

    /// Takes a change announced from elsewhere (a card moved on a board): the row shows it before any reload.
    func apply(_ c: Session.IssueChange) {
        edit { row, issue in
            guard c.targets.contains(row.target) else { return }
            if let fresh = c.issue { if fresh.key == issue.key { issue = fresh } } else { c.change?(&issue) }
        }
    }

    /// Changes the rows' copies of `keys` at once, ahead of Jira's answer.
    func patch(_ keys: [String], _ change: (inout Issue) -> Void) {
        edit { row, issue in if keys.contains(issue.key) { change(&issue) } }
    }

    /// Changes issues in place, on screen and in the pages behind the screen, keeping their order until the next
    /// load re-sorts. A row left equal is not reassigned: nothing redraws for a change that reached no row.
    private func edit(_ change: (ListRow, inout Issue) -> Void) {
        func run(_ rows: inout [ListRow]) -> Bool {
            var changed = false
            for i in rows.indices {
                var issue = rows[i].issue
                change(rows[i], &issue)
                guard issue != rows[i].issue else { continue }
                rows[i] = ListRow(issue: issue, state: rows[i].state)
                changed = true
            }
            return changed
        }
        var shown = rows
        if run(&shown) { rows = shown }
        for (id, page) in pages {
            var page = page
            if run(&page.rows) { pages[id] = page }
        }
    }

    /// Loads the filters: one account with pagination, or every account merged in the chosen order.
    func load(_ f: ListFilters, session: Session) async {
        generation += 1
        let gen = generation
        // Every row of the list is here: the last page is in, or the rows reach the count.
        let complete = !hasMore && !rows.isEmpty
        sort = f.sort
        unbounded = !f.isBounded
        queryError = nil
        if unbounded {
            rows = []
            pages = [:]
            query = nil
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
        if shownKey != queryKey {
            var byAccount = pages.mapValues(\.rows)
            var resorted = shown
            resorted.sort = f.sort
            if resorted == f, !rows.isEmpty {
                // Only the order changed. A list that is all here changes places at once, exactly, and the server's
                // page confirms it. A longer one would sort only the rows it has, and the server's first page would
                // swap them for others a moment later: it shows the new order's cached page if there is one, else
                // keeps the old order until the server answers, so the rows reorder once.
                if complete {
                    byAccount = byAccount.mapValues { $0.sorted { f.sort.areInOrder($0.issue, $1.issue) } }
                } else if cacheable {
                    let cached = await Self.cachedRows(queries)
                    guard gen == generation else { return }
                    if !cached.isEmpty { byAccount = cached }
                }
            } else {
                byAccount = cacheable ? await Self.cachedRows(queries) : [:]
                guard gen == generation else { return }
            }
            pages = Dictionary(
                uniqueKeysWithValues: states.map { ($0.id, Page(state: $0, rows: byAccount[$0.id] ?? [])) })
            show(merged())
            // Only now: a load superseded before its rows reached the screen must not let the next one skip them.
            shownKey = queryKey
        }
        shown = f
        query = (f.jql, f.jqlParts, cacheable)
        for id in pages.keys { (pages[id]!.part, pages[id]!.token) = (0, nil) }  // the first page replaces
        isLoading = true
        let tasks = pages.keys.map { id in Task { @MainActor in try await self.fetchPage(id, gen: gen) } }
        for t in tasks {
            let result = await t.result
            guard gen == generation else { return }
            // Of several sites, a failed one keeps what it had; alone, it says what went wrong.
            if case .failure(let e) = result, f.account != nil { fail(e, cacheable: cacheable) }
        }
        // The rows a reload kept below its first page are refreshed in place, page by page, as far as they reach.
        while gen == generation,
            let id = pages.first(where: { $0.value.more && $0.value.rows.count > $0.value.fetched })?.key
        {
            let before = pages[id]?.fetched
            do { try await fetchPage(id, gen: gen) } catch { break }
            if pages[id]?.fetched == before { break }  // an empty page that still says "more"
        }
        guard gen == generation else { return }
        isLoading = false
        // A merge holds rows back behind the account furthest behind; it still opens on a page's worth, as one site does.
        while gen == generation, hasMore, rows.count < 50 { await loadMore() }
        guard gen == generation else { return }
        if cacheable { Self.prefetchDetails(rows) }
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
            for i in issues where st.peek[i.key] == nil { st.peek[i.key] = i }
            out[st.id] = issues.map { ListRow(issue: $0, state: st) }
        }
        return out
    }

    /// Replaces the rows unless nothing changed: a refresh that brings the same page back must not redraw the list.
    /// `animated` for fresh rows replacing ones on screen: an edited issue glides to its new place, as in Mail,
    /// instead of every row jumping at once.
    private func show(_ new: [ListRow], animated: Bool = false) {
        guard new.count != rows.count || zip(new, rows).contains(where: { $0.id != $1.id || $0.issue != $1.issue })
        else { return }
        if animated, !rows.isEmpty {
            withAnimation(.smooth(duration: 0.35)) { rows = new }
        } else {
            rows = new
        }
    }

    /// Every account's rows in the chosen order, up to the last row of the account that is furthest behind: an
    /// account with a page still to come can only add rows that sort after its own last one, so everything from
    /// the others before that is final and nothing lands between rows already on screen. The others' rows that tie
    /// with that last row on the sort field wait too, as its next page can bring more of the tie. Ties keep Jira's
    /// order inside an account, so the waiting account's own rows all show: a site that dates to the second (Server)
    /// and a bulk edit made hundreds of rows tie, and the list opened on the dozen before them.
    /// One account shows as Jira sent it.
    private func merged() -> [ListRow] {
        if pages.count == 1 { return pages.values.first!.rows }
        return Self.merge(
            pages.keys.sorted { $0.uuidString < $1.uuidString }.map { pages[$0]!.rows },
            bound: waiting.flatMap { pages[$0]?.rows.last }, sort: sort)
    }

    /// `merged` for accounts' rows in a fixed order, `bound` the last row of the account the merge waits on.
    static func merge(_ accounts: [[ListRow]], bound: ListRow?, sort: ListFilters.Sort) -> [ListRow] {
        let rows = accounts.flatMap { own in
            guard let bound, own.first?.state !== bound.state else { return own }
            return own.filter {
                sort.compare($0.issue, bound.issue) != .orderedSame && sort.areInOrder($0.issue, bound.issue)
            }
        }
        // Stable, on the field alone: ties stay in Jira's order within an account, and in account order across them.
        let first: ComparisonResult = sort.descending ? .orderedDescending : .orderedAscending
        return rows.sorted { sort.compare($0.issue, $1.issue) == first }
    }

    /// The account the merge waits on: the one with more pages whose last row comes first.
    private var waiting: UUID? {
        pages.values.filter(\.more).min(by: {
            guard let a = $0.rows.last else { return true }
            guard let b = $1.rows.last else { return false }
            return sort.areInOrder(a.issue, b.issue)
        })?.state.id
    }

    /// The next page of the account the merge waits on, and the next again while nothing new reaches the screen:
    /// a page of rows that all tie with the last one adds nothing until the tie is passed.
    func loadMore() async {
        guard hasMore, !isLoading, let cache = query?.cache else { return }
        let gen = generation
        isLoading = true
        isLoadingMore = true
        // Not for a superseded page: the load that replaced it is still running under the same flag.
        defer {
            isLoadingMore = false
            if gen == generation { isLoading = false }
        }
        let before = rows.count
        while gen == generation, rows.count == before, let id = waiting {
            do { try await fetchPage(id, gen: gen) } catch { return fail(error, cacheable: cache) }
        }
    }

    /// One account's next page into its `Page` and onto the screen. A page from the start replaces the rows it
    /// covers, and the rows of the last load below them stay until a fresh page reaches them: a reload (the app
    /// coming to the front, an edit, the timer) took a long list back to its first page, and a merged one to the
    /// few rows before the furthest-behind account's 50th, then grew it back under the reader.
    private func fetchPage(_ id: UUID, gen: Int) async throws {
        guard let q = query, let p = pages[id] else { return }
        let page = try await Self.pageWorth(
            q.parts, whole: q.jql, part: p.part, token: p.token, state: p.state, cache: q.cache)
        guard gen == generation, pages[id] != nil else { return }
        let first = p.part == 0 && p.token == nil
        let fetched =
            (first ? [] : Array(p.rows.prefix(p.fetched))) + page.issues.map { ListRow(issue: $0, state: p.state) }
        let more = page.token != nil || page.part + 1 < q.parts.count
        pages[id]!.rows = Self.refreshed(p.rows, fetched: fetched, more: more)
        pages[id]!.fetched = fetched.count
        (pages[id]!.part, pages[id]!.token) = (page.part, page.token)
        pages[id]!.more = more
        show(merged(), animated: !isLoadingMore)
    }

    /// One account's rows during a load: what it fetched so far, then the last load's rows from where those end,
    /// less any the fresh pages already hold; none once the list has no more.
    static func refreshed(_ old: [ListRow], fetched: [ListRow], more: Bool) -> [ListRow] {
        let keys = Set(fetched.map(\.id))
        return fetched + (more ? old.dropFirst(fetched.count).filter { !keys.contains($0.id) } : [])
    }

    private func fail(_ error: Error, cacheable: Bool) {
        guard !error.isOffline, !error.isCancelled else { return }
        // A 400 on a typed search is the query itself; an alert would steal the keystrokes that fix it.
        if !cacheable, (error as? JiraError)?.status == 400 {
            queryError = error.localizedDescription
            rows = []
        } else {
            self.error = error.localizedDescription
        }
    }
}

struct IssueListView: View {
    @Binding var filters: ListFilters
    /// The selected rows; the main window owns them so Escape can clear them from anywhere. One row is the preview.
    @Binding var selection: Set<IssueTarget>
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
    /// The row last moved to a window of its own; the arrows carry on from it while nothing is selected.
    @State private var opened: IssueTarget?
    /// The one selected row, kept live for the arrows: in their handler `selection` reads as of the pass that made
    /// it, and a held key's repeats all go to the handler that took the first press.
    @State private var cursor: IssueTarget?
    /// The keyboard is in the preview beside the list: the selection goes grey, as Mail's does.
    @State private var previewFocused = false
    /// A plain press on one row of a multi-selection, and where: the mouse-up narrows the selection to it.
    @State private var pressed: (Int, NSPoint)?
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
    private var loadKey: LoadKey {
        LoadKey(filters: filters, reload: session.reloadTick, list: session.listTick, refresh: refreshTick)
    }
    /// Compared field by field: a string of the filters cost a reflection pass on every render.
    private struct LoadKey: Hashable {
        let filters: ListFilters
        let reload: Int
        let list: Int
        let refresh: Int
    }
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
        let picked = shown.map(\.row).filter { selection.contains($0.target) }
        // What the table has selected is the truth: SwiftUI builds this set from the table's changes since its
        // last pass, and when several land between passes (arrows queued behind a refresh) it adds the new row
        // without dropping the old one ("2 Issues Selected" after ⌘R and ↓).
        let listSelection = Binding<Set<IssueTarget>>(get: { selection }) { new in
            if new.count > 1, let t = NSApp.keyWindow?.contentView.flatMap(firstTable),
                t.selectedRowIndexes.count < new.count
            {
                let actual = Set(t.selectedRowIndexes.compactMap { $0 < shown.count ? shown[$0].row.target : nil })
                selection = actual.isEmpty ? new : actual
            } else {
                selection = new
            }
        }
        List(selection: listSelection) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, d in
                let row = d.row
                // The open issue stays in the accent colour while the window is active, as in Notes and Mail;
                // behind another window it goes grey like any selection. A run of selected rows is one block,
                // rounded at its ends only, as Mail paints it.
                let selected = selection.contains(row.target)
                let emphasized = selected && active && !previewFocused
                let above = i > 0 && selection.contains(shown[i - 1].row.target)
                let below = i + 1 < shown.count && selection.contains(shown[i + 1].row.target)
                IssueRow(
                    issue: row.issue,
                    site: isUnified && session.states.count > 1 ? (row.state.title, row.state.color) : nil,
                    date: filters.sort.date(of: row.issue), dayOnly: filters.sort.field == .due,
                    depth: d.depth, folded: d.children.count, expanded: expanded.contains(d.id),
                    toggle: d.children.isEmpty
                        ? nil : { withAnimation(.snappy(duration: 0.25)) { expanded.formSymmetricDifference([d.id]) } },
                    pending: store.pending.contains(row.issue.key)
                )
                // A new view after an edit, so the table measures the row again. The row's own id in it too: this id
                // is the table row's identity, and two issues with the same summary became one row, drawn twice.
                .id("\(d.id)|\(row.issue.fields.summary)")
                .tag(row.target)
                // The table's own highlight, grey without focus, is off: the rows paint theirs.
                .foregroundStyle(emphasized ? AnyShapeStyle(.white) : AnyShapeStyle(.foreground))
                .environment(\.backgroundProminence, emphasized ? .increased : .standard)
                .listRowBackground(
                    UnevenRoundedRectangle(
                        topLeadingRadius: above ? 0 : 6, bottomLeadingRadius: below ? 0 : 6,
                        bottomTrailingRadius: below ? 0 : 6, topTrailingRadius: above ? 0 : 6
                    )
                    // Unselected rows in the table's own colour, not clear: a row gliding to its new place
                    // passes over the others, and see-through it drew its text over theirs.
                    .fill(
                        emphasized
                            ? Color.accentColor
                            : selected
                                ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
                                : Color(nsColor: .controlBackgroundColor)
                    )
                    // 10, not 8: the ring AppKit draws around right-clicked rows then runs 1 pt inside this block on
                    // every side, as Mail's does; at 8 it sat 3 pt in at the sides and 1 pt at the top and bottom.
                    .padding(.horizontal, 10)
                    // Over the row gap, so two selected rows meet without a seam.
                    .padding(.top, above ? -3 : 0).padding(.bottom, below ? -3 : 0)
                )
                .listRowSeparator(selected && below ? .hidden : .automatic, edges: .bottom)
                .onAppear { if d.id == shown.last?.id { Task { await store.loadMore() } } }
                // Drag a row into Slack, a browser or a note as its Jira link.
                .itemProvider {
                    let p = NSItemProvider(object: row.state.client.browseURL(row.issue.key) as NSURL)
                    p.suggestedName = "\(row.issue.key) \(row.issue.fields.summary)"  // the .webloc's name in the Finder
                    return p
                }
            }
            // Only while there is nothing to show or the next page is coming: a refresh behind rows that are
            // already on screen must not add and remove a row at the end of the list (the table then re-applied
            // a selection a click had just changed, and the arrows were lost).
            if store.isLoading, store.rows.isEmpty || store.isLoadingMore {
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
        .background(NativeSelectionOff(previewFocused: $previewFocused))
        .onCopyCommand { keyItems(picked.map(\.issue.key)) }
        .contextMenu(forSelectionType: IssueTarget.self) { targets in
            // Over a selected row the menu acts on the whole selection, else on the row under the pointer.
            let rows = store.rows.filter { targets.contains($0.target) }
            if let state = rows.first?.state, rows.allSatisfy({ $0.state === state }) {
                IssueMenu(
                    issues: rows.map(\.issue), state: state, write: { act(keys: rows.map(\.issue.key), $0) },
                    patch: store.patch)
            }
        } primaryAction: { targets in
            // Double-click, ↩ or Space moves the issue to a window of its own, like a message in Mail: the preview
            // lets it go, so the same page is never open twice.
            for t in targets { openWindow(id: "issue", value: t) }
            opened = targets.first
            selection = []
        }
        // → unfolds a parent's subtasks; with nothing to unfold it moves the keyboard into the preview, whose ←
        // brings it back (the other way round right to left).
        .onKeyPress(.rightArrow) { sideways(towardPreview: layoutDirection == .leftToRight) }
        .onKeyPress(.leftArrow) { sideways(towardPreview: layoutDirection == .rightToLeft) }
        .onKeyPress(.space) {
            guard !selection.isEmpty else { return .ignored }
            for t in selection { openWindow(id: "issue", value: t) }
            opened = selection.first
            selection = []
            return .handled
        }
        .modifier(FollowsOtherWindows(store: store, selection: $selection, opened: $opened))
        .onKeyPress(keys: [.downArrow, .upArrow]) { step($0, by: $0.key == .downArrow ? 1 : -1) }
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
        .focusedSceneValue(
            \.selectedLinks, picked.count > 1 ? picked.map { $0.state.client.browseURL($0.issue.key) } : nil
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
            if filters.isKey { openKey() } else { session.recordSearch(filters.text) }
        }
        // A pasted Jira link becomes its key at once, on the account of the link's site when one is signed in.
        .onChange(of: filters.text) { _, text in
            guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                url.scheme?.hasPrefix("http") == true, let key = Session.issueKey(in: url)
            else { return }
            if let st = session.state(host: url.host() ?? ""), filters.account != st.id { setAccount(st.id) }
            filters.text = key
            // A turn later: the main window drops the selection when the account changes, and this lands after it.
            DispatchQueue.main.async { openKey() }
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
                    .help("Open the project board (⇧⌘B)")
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
        // Another list (a sidebar click, a chip): the search field lets the keyboard go, whatever it held. Text
        // typed or cleared in it is the same list, and keeps it there.
        .onChange(of: filters) { old, new in
            var sameButText = old
            sameButText.text = new.text
            if sameButText != new { searchFocused = false }
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
            cursor = new.count == 1 ? new.first : nil
            guard !new.isEmpty else { return }
            searchFocused = false  // or SwiftUI hands the keyboard straight back to the search field
            NSApp.keyWindow?.focusList()
        }
        // ↓ in the search field goes on to the results, as in Spotlight, unless completions are showing. A click
        // on the rows takes the keyboard from the search field before the table sees it, so a click on the row
        // that is already selected takes it too (the selection does not change, so onChange above never fires).
        .background(
            WindowEventMonitor(mask: [.keyDown, .leftMouseDown, .leftMouseUp]) { e in
                if e.type != .keyDown {
                    guard let w = e.window, let table = w.contentView.flatMap(firstTable),
                        table.convert(table.bounds, to: nil).contains(e.locationInWindow)
                    else { return e }
                    let row = table.row(at: table.convert(e.locationInWindow, from: nil))
                    if e.type == .leftMouseDown {
                        if w.firstResponder !== table {
                            searchFocused = false
                            w.makeFirstResponder(table)
                        }
                        // A plain click on one row of a multi-selection: AppKit narrows the selection to that row
                        // on the mouse-up (the press may start a drag instead); SwiftUI's list leaves it as it is.
                        // Done on the table, not the binding: the binding reaches the table a turn later and would
                        // then undo the arrows pressed in between.
                        let plain = e.modifierFlags.intersection([.command, .shift]).isEmpty
                        pressed =
                            plain && row >= 0 && table.selectedRowIndexes.count > 1 && table.isRowSelected(row)
                            ? (row, e.locationInWindow) : nil
                    } else if let (r, at) = pressed {
                        pressed = nil
                        if hypot(e.locationInWindow.x - at.x, e.locationInWindow.y - at.y) < 3 {
                            table.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
                        }
                    }
                    return e
                }
                // The window's one field editor serves the search and the page's summary editor alike: the search,
                // where JQL goes, gets no text replacement or autocorrection; the others what the system says.
                if let tv = e.window?.firstResponder as? NSTextView, tv.isFieldEditor {
                    let search = tv.delegate is NSSearchField
                    tv.isAutomaticTextReplacementEnabled = !search && NSSpellChecker.isAutomaticTextReplacementEnabled
                    tv.isAutomaticSpellingCorrectionEnabled =
                        !search && NSSpellChecker.isAutomaticSpellingCorrectionEnabled
                    // Nor ". " for two spaces: the input context adds it, and no switch on the text view turns it
                    // off, so a space goes in directly.
                    if search, e.keyCode == 49, e.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                        !tv.hasMarkedText()
                    {
                        tv.insertText(" ", replacementRange: tv.selectedRange())
                        return nil
                    }
                }
                // Arrows carry the function and numeric-pad flags, so only the real modifiers count.
                guard e.keyCode == 125, e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                    let tv = e.window?.firstResponder as? NSTextView, tv.isFieldEditor, tv.delegate is NSSearchField,
                    suggestions.isEmpty, !shown.isEmpty
                else { return e }
                if selection.isEmpty, let first = shown.first?.row.target { selection = [first] }
                searchFocused = false
                NSApp.keyWindow?.focusList()
                return nil
            }
        )
        .errorAlert($store.error)
    }

    /// A key opens its issue at once: the list shows the row and the preview shows the page. The list's account
    /// decides, else the one account with that project; with several, no guess: the list shows a row per account
    /// and the keyboard goes to it, so ↓ picks one.
    private func openKey() {
        let key = filters.text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let project = key.prefix { $0 != "-" }
        let owners = session.states.filter { $0.projects.contains { $0.key == project } }
        searchFocused = false
        if let st = filters.account.flatMap(session.state) ?? (owners.count > 1 ? nil : session.state(forKey: key)) {
            selection = [IssueTarget(accountID: st.id, key: key)]
        } else {
            NSApp.keyWindow?.focusList()
        }
    }

    private var suggestionRows: some View {
        ForEach(suggestions, id: \.completion) { s in Text(s.display).searchCompletion(s.completion) }
    }

    /// A load already in flight is as fresh as a new one would be; restarting it (the app activating at launch
    /// did) would only throw its answer away.
    private func refresh() { if !store.isLoading { refreshTick += 1 } }

    /// A plain ↓ or ↑ steps from the one selected row, or, back from an issue opened in its own window, from that
    /// issue rather than the top of the list. Here, not in the table: SwiftUI writes its selection back into the table
    /// a pass late, and steps the table took in between were undone. Shift and the other arrows stay the table's, as
    /// does a multi-selection.
    private func step(_ press: KeyPress, by delta: Int) -> KeyPress.Result {
        let shown = displayRows  // not the body's: a held key reaching the end goes on into the next page
        let plain = press.modifiers.isDisjoint(with: [.shift, .option, .command, .control])
        let current = cursor.map { [$0] } ?? selection
        guard let row = current.isEmpty ? opened : (plain && current.count == 1 ? current.first : nil),
            let i = shown.firstIndex(where: { $0.row.target == row })
        else { return .ignored }
        let target = shown[max(0, min(shown.count - 1, i + delta))].row.target
        selection = [target]
        cursor = target
        opened = nil
        // The list glides after the row with room to spare, for as long as the arrows stay on it, finding it again
        // each time. A held key moves at once: a glide begun again on every repeat lagged rows behind the selection.
        if let table = NSApp.keyWindow?.contentView.flatMap(firstTable), let sv = table.enclosingScrollView {
            sv.reveal(
                {
                    guard cursor == target, let j = displayRows.firstIndex(where: { $0.row.target == target }),
                        j < table.numberOfRows
                    else { return nil }
                    return sv.contentView.convert(table.rect(ofRow: j), from: table)
                }, room: 12, animated: press.phase != .repeat)
        }
        return .handled
    }

    private func sideways(towardPreview: Bool) -> KeyPress.Result {
        let r = fold(open: towardPreview)
        guard r == .ignored, towardPreview, selection.count == 1, NSApp.keyWindow?.focusPreviewPage() == true else {
            return r
        }
        return .handled
    }

    /// → unfolds the selected parent's subtasks, ← folds them, as in an outline (the other way round right to left).
    private func fold(open: Bool) -> KeyPress.Result {
        guard selection.count == 1, let sel = selection.first,
            let d = displayRows.first(where: { $0.row.target == sel }), !d.children.isEmpty,
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
            ? nil : issues(store.count, more: store.total == nil && store.hasMore)
    }

    // MARK: Row actions

    /// Runs a write with its rows marked busy, then reloads the list and the open issue so both show the result;
    /// the rows already show what the menu patched in, so the reload only confirms and re-sorts.
    private func act(keys: [String], _ op: @escaping () async throws -> Void) {
        store.pending.formUnion(keys)
        Task {
            do { try await op() } catch { store.error = error.localizedDescription }
            store.pending.subtract(keys)
            keys.forEach(session.touched)
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
/// What the list takes from other windows, as they happen.
private struct FollowsOtherWindows: ViewModifier {
    let store: IssueListStore
    @Binding var selection: Set<IssueTarget>
    @Binding var opened: IssueTarget?
    @Environment(Session.self) private var session

    func body(content: Content) -> some View {
        content
            // The previewed issue opened in a window some other way (a link, Spotlight, Open in New Window): the
            // preview lets it go as for a double-click, and the arrows carry on from it.
            .onChange(of: session.windowOpened?.count) {
                guard let t = session.windowOpened?.target, selection == [t] else { return }
                opened = t
                selection = []
            }
            // A change made elsewhere (a card moved on a board) shows in its row at once.
            .onChange(of: session.lastChange?.count) { if let c = session.lastChange { store.apply(c) } }
    }
}

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
    /// A write to this issue is on its way to Jira: a spinner beside the status.
    var pending = false
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
                    if pending { ProgressView().controlSize(.mini).fixedSize() }
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

/// The right-click menu for issues anywhere: list rows and board cards share it. With several issues selected it
/// acts on all of them; what applies to only some (a status, "Assign to Me") shows for the ones it fits.
struct IssueMenu: View {
    let issues: [Issue]
    let state: AccountState
    /// Runs a write and refreshes whatever the owner shows.
    var write: (@escaping @Sendable () async throws -> Void) -> Void
    /// Applies what the write will do to the owner's copies of `keys` at once, before Jira answers.
    var patch: (_ keys: [String], _ change: @escaping (inout Issue) -> Void) -> Void = { _, _ in }
    @Environment(Session.self) private var session
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let keys = issues.map(\.key)
        let targets = keys.map { IssueTarget(accountID: state.id, key: $0) }
        let urls = keys.map(state.client.browseURL)
        let watching = issues.allSatisfy { $0.fields.watches?.isWatching == true }
        let me = state.me?.accountId
        let many = issues.count > 1
        // The Issue menu's order: open, copy, then the writes as one group. Plural when the menu acts on several.
        Button("Open in Browser", systemImage: "safari") { urls.forEach { NSWorkspace.shared.open($0) } }
        Button(many ? "Open in New Windows" : "Open in New Window", systemImage: "macwindow.badge.plus") {
            targets.forEach { openWindow(id: "issue", value: $0) }
        }
        if !many, let issue = issues.first {
            Button("Clone…", systemImage: "doc.on.doc") {
                openWindow(
                    id: "create",
                    value: CreateRequest(
                        accountID: state.id, projectKey: issue.fields.project?.key, cloneKey: issue.key))
            }
        }
        Divider()
        Button(many ? "Copy Links" : "Copy Link", systemImage: "link") {
            copyToPasteboard(urls.map(\.absoluteString).joined(separator: " "))
        }
        Button(many ? "Copy Keys" : "Copy Key", systemImage: "number") {
            copyToPasteboard(keys.joined(separator: " "))
        }
        ShareLink(items: urls)
        Divider()
        // From the account's cache: a menu's content is fixed once open, so nothing can load inside it. Issues of
        // different workflows have different transitions, so the submenu needs them all on one.
        let workflows = Set(issues.map(AccountState.workflowKey))
        if workflows.count > 1 {
            Button("Change Status", systemImage: "arrow.right.circle") {}.disabled(true)
        } else if let transitions = state.transitionsByWorkflow[workflows.first!] {
            Menu("Change Status", systemImage: "arrow.right.circle") {
                ForEach(transitions) { t in
                    Toggle(
                        isOn: Binding(
                            get: { t.to.id == issues.first?.fields.status.id },
                            set: { on in
                                guard on else { return }
                                let (old, account) = (issues.map(\.fields.status), state.id)
                                patch(keys) { $0.fields.status = t.to }
                                write {
                                    try await parallel(
                                        zip(keys, old).map { key, status in
                                            {
                                                try await state.client.transition(key, to: t.id)
                                                await Bin.shared.put(.status(status), account: account, key: key)
                                            }
                                        })
                                }
                            })
                    ) { Text(t.name) }
                }
            }
        } else if let target = targets.first {
            // Not cached yet: the page loads the transitions, and the menu has them the next time.
            Button("Change Status…", systemImage: "arrow.right.circle") {
                openWindow(id: "issue", value: target)
                state.warmTransitions(issues)
            }
        }
        // Greyed rather than gone when there is nothing to do, as in the Issue menu.
        let notMine = issues.filter { $0.fields.assignee?.accountId != me }.map(\.key)
        Button("Assign to Me", systemImage: "person.crop.circle.badge.checkmark") {
            guard let me else { return }
            patch(notMine) { $0.fields.assignee = state.me }
            write { try await parallel(notMine.map { key in { try await state.client.assign(key, to: me) } }) }
        }
        .disabled(me == nil || notMine.isEmpty)
        let assigned = issues.filter { $0.fields.assignee != nil }.map(\.key)
        Button("Unassign", systemImage: "person.crop.circle.badge.minus") {
            patch(assigned) { $0.fields.assignee = nil }
            write { try await parallel(assigned.map { key in { try await state.client.assign(key, to: nil) } }) }
        }
        .disabled(assigned.isEmpty)
        Button(watching ? "Unwatch" : "Watch", systemImage: watching ? "eye.slash" : "eye") {
            patch(keys) {
                let n = $0.fields.watches?.watchCount ?? 0
                $0.fields.watches = Watches(watchCount: max(0, n + (watching ? -1 : 1)), isWatching: !watching)
            }
            write { try await parallel(keys.map { key in { try await state.client.watch(key, !watching, me: me) } }) }
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
            // A field starts in its natural direction: due dates soonest first, everything else newest or highest first.
            Toggle(
                f.title,
                isOn: Binding(
                    get: { sort.field == f }, set: { if $0 { sort = .init(field: f, descending: f != .due) } }))
        }
        Divider()
        Toggle("Ascending", isOn: Binding(get: { !sort.descending }, set: { if $0 { sort.descending = false } }))
        Toggle("Descending", isOn: Binding(get: { sort.descending }, set: { if $0 { sort.descending = true } }))
    }
}

/// Turns off the table's own selection drawing; the rows paint theirs. Behind the list rather than inside a
/// row: a platform view in a row put the first frame back by ~60 ms.
struct NativeSelectionOff: NSViewRepresentable {
    /// Set while the keyboard is in the preview column of this window.
    var previewFocused: Binding<Bool>?
    func makeNSView(context: Context) -> Finder { Finder() }
    func updateNSView(_ view: Finder, context: Context) { view.previewFocused = previewFocused }
    final class Finder: NSView {
        var previewFocused: Binding<Bool>?
        nonisolated(unsafe) private var monitor: Any?
        nonisolated(unsafe) private var observer: Any?
        override func viewDidMoveToWindow() { find(attempt: 0) }
        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        /// The table is a sibling subtree: the nearest ancestor with one below it, short of the split view that
        /// also holds the sidebar's. It can arrive a turn after this view, hence the retries.
        private func find(attempt: Int) {
            guard window != nil else { return }
            var v = superview
            while let s = v, !(s is NSSplitView) {
                if let table = firstTable(in: s) {
                    table.selectionHighlightStyle = .none
                    table.allowsTypeSelect = false  // letters are shortcuts here, not a jump to a row
                    watch(table)
                    return
                }
                v = s.superview
            }
            if attempt < 10 { DispatchQueue.main.async { self.find(attempt: attempt + 1) } }
        }

        private func watch(_ table: NSTableView) {
            if let monitor { NSEvent.removeMonitor(monitor) }
            // Page Up and Down, Home and End scroll the list smoothly; the table's own jump lands in one frame.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak table] e in
                guard let table, e.window === table.window, table.window?.firstResponder === table,
                    let sv = table.enclosingScrollView, sv.scrollAnimated(for: e, line: 0, arrows: false)
                else { return e }
                return nil
            }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = NotificationCenter.default.addObserver(
                forName: .previewFocus, object: table.window, queue: .main
            ) { [weak self] n in
                let on = n.userInfo?["on"] as? Bool ?? false
                MainActor.assumeIsolated { self?.previewFocused?.wrappedValue = on }
            }
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

/// Runs the writes at once rather than one after the other; the first failure is thrown once all have returned.
func parallel(_ ops: [@Sendable () async throws -> Void]) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        for op in ops { group.addTask { try await op() } }
        try await group.waitForAll()
    }
}
