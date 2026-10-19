import AppKit
import SwiftUI

/// One row of a list: the issue and the account it came from. A class: every pass over a list of thousands (its
/// merge, its nesting, each refresh's comparison) copied each row's whole issue, and a row the pass did not change
/// is the same object, so the comparison skips it.
final class ListRow: Identifiable, Sendable {
    let issue: Issue
    let state: AccountState
    /// Made once: every pass over the list (its diff, the nesting, each row) asked for it, a UUID printed each time.
    let id: String
    init(issue: Issue, state: AccountState) {
        (self.issue, self.state, id) = (issue, state, "\(state.id)|\(issue.key)")
    }
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
            // Each row's date worked out once: in the comparison, it cost every comparison a pass over the children.
            let dated: [(row: ListRow, date: Date)] = top.map { r in
                let kids = children[r.id]?.compactMap(\.issue.fields.updated).max() ?? .distantPast
                return (r, max(r.issue.fields.updated ?? .distantPast, kids))
            }
            let descending = sort.descending
            top = dated.sorted { a, b in
                a.date != b.date ? (descending ? a.date > b.date : a.date < b.date) : a.row.id < b.row.id
            }
            .map(\.row)
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

/// A list as `IssueListStore.load` tells lists apart: the accounts it spans and its JQL, the order included. A typed
/// search is a list too, but none whose place is kept (see `ScrollMemory`).
struct ListKey: Hashable, Codable, Sendable {
    var accounts: [UUID]
    var jql: String
    var typed = false
}

@MainActor @Observable
final class IssueListStore {
    var rows: [ListRow] = [] { didSet { nested = nil } }
    /// `DisplayRow.nest` of `rows`, until they, the unfolded parents or the order change: the body, each arrow press
    /// and each fold asked for it again, a pass over every row each time.
    @ObservationIgnored private var nested: (expanded: Set<String>, sort: ListFilters.Sort, rows: [DisplayRow])?
    /// In the order of the list the rows are of (`shown`): from a click on another list to its rows landing, the
    /// chips have its order already, and the rows on screen sorted by it moved for a few frames.
    func displayRows(expanded: Set<String>) -> [DisplayRow] {
        let (rows, sort) = (rows, shown.sort)  // read either way: the caller redraws when they change
        if let n = nested, n.expanded == expanded, n.sort == sort { return n.rows }
        let out = DisplayRow.nest(rows, expanded: expanded, sort: sort)
        nested = (expanded, sort, out)
        return out
    }
    /// Ids of selected rows a reload no longer brings (an edit took them out of the list): they stay where they
    /// were, greyed, until the selection leaves them, so the preview's issue keeps its place for the arrows.
    private(set) var stale: Set<String> = []
    /// The list's selection, as `keep` was last told.
    private var kept: Set<IssueTarget> = []
    /// Keys with a write on its way to Jira.
    var pending: Set<String> = []
    /// The row under the pointer, the one with tooltips. Not watched: read by every row, a pointer crossing one row's
    /// border redrew them all; the table shows the two rows it changes again (see `IssueTable.Coordinator.hover`).
    @ObservationIgnored var hovered: String?
    /// One account's share of the list: its rows so far and where its next page starts.
    private struct Page {
        let state: AccountState
        var rows: [ListRow] { didSet { ids = nil } }
        /// The part of the list (see `ListFilters.jqlParts`) the next page comes from, and the page's token.
        var part = 0
        var token: String?
        /// How many of `rows` this load fetched; the rest are the last load's, kept below them (see `fetchPage`).
        var fetched = 0 { didSet { ids = nil } }
        /// The ids of the rows fetched, as the last page left them; nil once anything else changed the rows. Made anew
        /// from the rows for every page, a long download hashed every row fetched so far again each page.
        var ids: Set<String>?
        /// More rows to load: a next page, or a part not started. A page not fetched yet (cached, or kept from the
        /// last load) is taken to have more when it is a full page, so the merge holds the same rows back.
        var more: Bool
        /// The rows run to the list's end, or to `cap`: fetched to there, or the whole list from disk. A refresh
        /// brings them up to date (see `sync`) rather than fetching them again.
        var full = false
        /// The rows are current from then on: when the download or the sync that brought them started, or the date
        /// of the whole list on disk. Nil before a download has started.
        var since: Date?
        init(state: AccountState, rows: [ListRow], more: Bool? = nil, full: Bool = false, since: Date? = nil) {
            (self.state, self.rows, self.more, self.full, self.since) =
                (state, rows, more ?? (rows.count >= 50), full, since)
        }
        /// A refresh brings the rows up to date rather than fetching them: they are whole, run past the first page,
        /// and are known to be current from some time on.
        var syncs: Bool { full && more && since != nil }
    }
    /// Not watched: a page fetched again with the same rows (a reload refreshes them all) redrew the whole list.
    /// What the screen shows of them is `rows` and `hasMore`.
    @ObservationIgnored private var pages: [UUID: Page] = [:] {
        didSet {
            let more = pages.values.contains(where: \.more)
            if more != hasMore { hasMore = more }
            let all = !pages.values.contains { $0.more && !$0.full }
            if all != complete { complete = all }
            if all, endPending { endPending = false }
        }
    }
    private var query: (jql: String, parts: [String], cache: Bool)?
    private(set) var hasMore = false
    /// Every row of the list is here (up to `cap` an account): End can go to the last one.
    private(set) var complete = true
    /// End was pressed before every row was here: the spinner shows under the rows, and the list stays on it until
    /// the last row is in, then lands there.
    var endPending = false
    /// Rows fetched behind the screen since it last showed them (see `fill`).
    @ObservationIgnored private var unshown = false

    /// Rows a list loads ahead per account: past it, End stops there and the count still says how many match.
    static let cap = 5000
    /// How many issues the query matches on the server, every account summed: the last count from the cache until
    /// this load's own answers. Nil when no count is known yet.
    var total: Int?
    /// The subtitle's number: the rows once the whole list is loaded, else the server's count.
    var count: Int {
        let n = rows.count - stale.count
        return query != nil && !hasMore && !isLoading ? n : max(total ?? 0, n)
    }
    /// The rows the count says are still to come while the list loads its pages, up to `cap` an account: the table
    /// keeps room for them (see `IssueTable.toCome`). None before the first rows, once all are here or the load
    /// stopped, or with no count.
    var toCome: Int {
        guard isLoading, !complete, !rows.isEmpty, let total else { return 0 }
        return max(0, min(total, Self.cap * pages.count) - (rows.count - stale.count))
    }
    /// True from the start: a new list is always about to load, and must not flash "No issues" first.
    var isLoading = true
    /// The next page is on its way: the only load that shows a spinner under rows already on screen.
    var isLoadingMore = false
    /// The last row that has been on screen. The spinner waits for it: the next page starts ten rows before the end,
    /// and a spinner row put in and taken out below the screen cost the table a pass over every row, twice a page.
    var lastShown: String?
    var error: String?
    /// The filters restrict nothing, which Jira refuses; the list explains instead of asking.
    var unbounded = false
    /// Jira rejected a typed query (half-written JQL, usually). Shown in the list, never as an alert.
    var queryError: String?
    private var generation = 0
    /// The query whose rows (cached or fresh) are on screen.
    private(set) var shownKey: ListKey?
    /// The filters whose rows are on screen.
    private(set) var shown = ListFilters()
    private var sort = ListFilters.Sort()

    /// One page of a query for one account, remembered as peeks for the issue page. With `cache` on, the rows that
    /// changed since the app last saw them go to Spotlight, and a first page is saved to disk unless `remembers` is
    /// off (a query no list opens). Shared by the list and the launch prefetch.
    static func fetch(
        jql: String, state: AccountState, nextPageToken: String? = nil, cache: Bool, size: Int = 50,
        remembers: Bool = true
    ) async throws -> SearchPage {
        let page = try await state.client.search(jql: jql, nextPageToken: nextPageToken, maxResults: size)
        // The rows' icons and avatars from disk into memory on other threads, before any row is made: a row's first
        // layout read and decoded each on the main thread. One not on disk yet is still the row's to fetch.
        let urls = AccountState.imageURLs(page.issues, projects: [], me: nil)
        await Task.detached(priority: .userInitiated) { ImageCache.warm(urls) }.value
        // Any change Jira makes moves `updated`: a row seen at the same one is already in Spotlight as it is.
        let changed = page.issues.filter { state.peek[$0.key]?.fields.updated != $0.fields.updated }
        for issue in page.issues { state.peek[issue.key] = issue }
        state.warmTransitions(page.issues)
        if cache {
            if nextPageToken == nil, remembers { remember(page.issues, jql: jql, state: state) }
            Spotlight.index(changed, host: state.host)
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
        _ parts: [String], whole jql: String, part: Int, token: String?, state: AccountState, cache: Bool,
        size: Int = 50
    ) async throws -> (issues: [Issue], part: Int, token: String?) {
        let first = part == 0 && token == nil
        var (issues, part, token) = ([Issue](), part, token)
        while true {
            // A part's own first page is not a list anyone opens: only the whole is cached, below.
            let page = try await fetch(
                jql: parts[part], state: state, nextPageToken: token, cache: cache, size: size,
                remembers: parts.count == 1)
            issues += page.issues
            token = page.isLast == true ? nil : page.nextPageToken
            guard token == nil, part + 1 < parts.count else { break }
            part += 1
            if issues.count >= size { break }
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
        edit({ c.targets.contains($0.target) }) { issue in
            if let fresh = c.issue { if fresh.key == issue.key { issue = fresh } } else { c.change?(&issue) }
        }
    }

    /// Changes the rows' copies of `keys` at once, ahead of Jira's answer.
    func patch(_ keys: [String], _ change: (inout Issue) -> Void) {
        edit({ keys.contains($0.issue.key) }, change)
    }

    /// Changes issues in place, on screen and in the pages behind the screen, keeping their order until the next
    /// load re-sorts. A row left equal is not reassigned: nothing redraws for a change that reached no row. Only the
    /// rows `picks` names are copied and compared: every row's whole issue, the screen's and again the pages', made
    /// an edit two of the passes that took 11 ms on 2,500 rows (see `IssueTable.Coordinator.RowKey`).
    private func edit(_ picks: (ListRow) -> Bool, _ change: (inout Issue) -> Void) {
        func run(_ rows: inout [ListRow]) -> Bool {
            var changed = false
            for i in rows.indices where picks(rows[i]) {
                var issue = rows[i].issue
                change(&issue)
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
        let complete = self.complete && !rows.isEmpty
        sort = f.sort
        unbounded = !f.isBounded
        queryError = nil
        if unbounded {
            rows = []
            stale = []
            pages = [:]
            query = nil
            total = nil
            shownKey = nil
            shown = f
            isLoading = false
            return
        }
        let states = session.states.filter { f.includes($0.id) }
        let queries: [(AccountState, String)] = states.map { ($0, f.jql) }
        // Typed searches are not cached: they change with every keystroke and would litter the disk.
        let cacheable = f.text.isEmpty
        total = queries.reduce(0 as Int?) { sum, q in
            guard let sum, let c = q.0.listCounts["list-" + DiskCache.hash(q.1)] else { return nil }
            return sum + c
        }
        Task { await countIssues(queries, gen: gen, cache: cacheable) }
        let queryKey = ListKey(accounts: states.map(\.id), jql: f.jql, typed: !cacheable)
        let opening = shownKey != queryKey
        // Each account's rows stay put (from cache on a new query, else what is shown) until its own fresh
        // page lands, so the list never collapses to the fastest site and then grows back.
        var sorted = false
        if opening {
            endPending = false
            var byAccount = pages.mapValues(\.rows)
            let since = pages.mapValues(\.since)
            var resorted = shown
            resorted.sort = f.sort
            if resorted == f, !rows.isEmpty {
                // Only the order changed. A list that is all here changes places at once, and its sync confirms it
                // with no first page over it, which would reorder its top a second time. Jira orders types and
                // statuses by the site's own sequence, so one account keeps its order until Jira's lands. A longer
                // list would sort only the rows it has, and the server's first page would swap them for others a
                // moment later: it shows the new order's cached page if there is one, else keeps the old order until
                // the server answers, so the rows reorder once.
                if complete {
                    if pages.count > 1 || ![.type, .status].contains(f.sort.field) {
                        byAccount = byAccount.mapValues { $0.sorted { f.sort.areInOrder($0.issue, $1.issue) } }
                    }
                    sorted = true
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
                uniqueKeysWithValues: states.map {
                    (
                        $0.id,
                        Page(
                            state: $0, rows: byAccount[$0.id] ?? [], full: sorted,
                            since: sorted ? since[$0.id] ?? nil : nil)
                    )
                })
            // The last list's rows behind the screen are not this one's: none goes on screen under its name meanwhile.
            unshown = false
            // Its place past the rows of its first pages (see `ScrollMemory`): the whole list first, so that the list's
            // first frame stands on it.
            if let place = ScrollMemory.place(queryKey)?.anchors, !place.isEmpty,
                [nil, .end].contains(IssueTable.Coordinator.restored(place, in: merged().map(\.id)))
            {
                await restoreWhole(queries, gen: gen, shows: false)
                guard gen == generation else { return }
            }
            // Another query: a row it lacks was never in it. Another order of the same list: a selected row the new
            // order's first rows lack stays, greyed, until a page brings it, or the sort dropped the preview's row.
            show(merged(), keep: resorted == f)
            // Only now: a load superseded before its rows reached the screen must not let the next one skip them.
            shownKey = queryKey
        }
        shown = f
        query = (f.jql, f.jqlParts, cacheable)
        isLoading = true
        let started = Date()
        let whole = opening && cacheable && !sorted ? Task { await restoreWhole(queries, gen: gen) } : nil
        let tasks = pages.filter { !sorted || !$0.value.syncs }.keys.map { id in
            Task { @MainActor in try await self.fetchPage(id, gen: gen, first: true) }
        }
        for t in tasks {
            let result = await t.result
            guard gen == generation else { return }
            // Of several sites, a failed one keeps what it had; alone, it says what went wrong.
            if case .failure(let e) = result, f.account != nil { fail(e, cacheable: cacheable) }
        }
        await whole?.value
        guard gen == generation else { return }
        if cacheable { Self.prefetchDetails(rows) }
        await fill(gen: gen, started: started)
        guard gen == generation else { return }
        isLoading = false
        endPending = false  // a site that failed on the way: the spinner goes, the list stays where it is
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
        if gen == generation, total != sum { total = sum }
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

    /// The whole list as it was last loaded to its end ("listfull-<hash of JQL>"), decoded at launch only for a place
    /// past its first page (see `Session.prepare`).
    nonisolated static func wholeName(_ jql: String) -> String { "listfull-" + DiskCache.hash(jql) }

    /// Each account's whole list from disk, read off the main thread (from memory when launch decoded it), under the
    /// rows this load already has: a list opened again is whole at once, and a sync brings it up to date from the
    /// file's date. A first page that ends the list, or rows fetched to the end already, need nothing from disk.
    private func restoreWhole(_ queries: [(AccountState, String)], gen: Int, shows: Bool = true) async {
        var changed = false
        func take(_ st: AccountState, _ issues: [Issue], _ date: Date?) {
            guard let p = pages[st.id], p.more, !p.full else { return }
            pages[st.id]!.rows = Self.refreshed(
                issues.map { ListRow(issue: $0, state: st) }, fetched: p.rows, more: true)
            pages[st.id]!.full = true
            pages[st.id]!.since = date
            changed = true
        }
        var reads: [(AccountState, Task<([Issue], Date?)?, Never>)] = []
        for (st, jql) in queries where pages[st.id].map({ $0.more && !$0.full }) == true {
            let name = Self.wholeName(jql)
            if let hit = Session.launchWhole(name, account: st.id) {
                take(st, hit, DiskCache.modified(account: st.account, name: name))
                continue
            }
            let read = Task.detached(priority: .userInitiated) { [account = st.account] in
                DiskCache.load([Issue].self, account: account, name: name).map {
                    ($0, DiskCache.modified(account: account, name: name))
                }
            }
            reads.append((st, read))
        }
        for (st, read) in reads {
            guard let (issues, date) = await read.value, gen == generation else { continue }
            take(st, issues, date)
        }
        if changed, shows { show(merged()) }
    }

    /// Every account's rows to the list's end (or `cap`) behind its first page: a list whole already is brought up to
    /// date (see `sync`); any other is fetched one page after another per account, accounts side by side, each page
    /// the largest the site serves, once.
    /// The pages go on screen when the list is whole, or as they come while the reader is at the end of the rows
    /// showing: each time, the rows are merged, nested and compared whole, which a page of rows per second of a long
    /// Cloud list made a stall a second. End waits for the last one, on the spinner.
    private func fill(gen: Int, started: Date) async {
        isLoadingMore = true
        defer { if gen == generation { isLoadingMore = false } }
        let tasks = pages.keys.map { id in Task { @MainActor in await self.fill(id, gen: gen, started: started) } }
        for t in tasks { await t.value }
        if gen == generation, unshown { show(merged()) }  // a site that failed on the way
    }

    private func fill(_ id: UUID, gen: Int, started: Date) async {
        guard let start = pages[id] else { return }
        if start.syncs { return await sync(id, gen: gen, started: started) }
        // A download an edit's reload took over goes on from its page, then catches up with what changed meanwhile.
        let resumed = start.since != nil && !start.full
        if start.since == nil { pages[id]!.since = started }
        let size = start.state.client.largestPage
        while gen == generation, let p = pages[id], p.more, p.fetched < Self.cap {
            do { try await fetchPage(id, gen: gen, size: min(size, Self.cap - p.fetched), shows: false) } catch {
                return
            }
            if pages[id]?.fetched == p.fetched { return }  // an empty page that still says "more"
            if !endPending, lastShown == rows.last?.id { show(merged()) }
        }
        guard gen == generation, let q = query, var p = pages[id] else { return }
        if p.more { p.rows = Array(p.rows.prefix(Self.cap)) }  // the last load's rows past the cap go
        p.full = true
        pages[id] = p
        show(merged())
        if q.cache, p.fetched > 50 {
            DiskCache.saveAsync(
                p.rows.map(\.issue), account: p.state.account, name: Self.wholeName(q.jql), asOf: p.since)
        }
        if resumed, p.syncs { await sync(id, gen: gen, started: started) }
    }

    /// One account's whole list brought up to date without fetching it again: its keys in the server's order, the
    /// rows changed since it was last current (its query narrowed to them, with five minutes of slack for the clocks
    /// and for what changed while that pass ran), and by key the few it lists that neither has (an issue viewed on the
    /// web joins Recently Viewed unchanged). A failure leaves the rows as they are, for the next pass.
    private func sync(_ id: UUID, gen: Int, started: Date) async {
        guard let q = query, let p = pages[id], let since = p.since else { return }
        let st = p.state
        let minutes = Int(started.timeIntervalSince(since) / 60) + 5
        async let sweep = Self.keys(q.parts, state: st)
        async let delta = Self.all(Self.changed(q.jql, minutes: minutes), state: st, cache: q.cache)
        guard let (keys, more) = try? await sweep, let changed = try? await delta, gen == generation,
            let now = pages[id]
        else { return }
        let have = Set(now.rows.map(\.issue.key)).union(changed.map(\.key))
        let missing = keys.filter { !have.contains($0) }
        var found: [Issue] = []
        for start in stride(from: 0, to: missing.count, by: 100) {
            let batch = missing[start..<min(start + 100, missing.count)].map { "\"\($0)\"" }
            guard
                let got = try? await Self.all(
                    "issuekey in (\(batch.joined(separator: ",")))", state: st, cache: q.cache)
            else { break }
            found += got
        }
        guard gen == generation, let now = pages[id] else { return }
        // Off the main thread: thousands of rows, keyed and compared, held a frame of a sort change.
        let fresh = (changed + found).map { ListRow(issue: $0, state: st) }
        let sort = sort
        var rows = await Task.detached(priority: .userInitiated) {
            Self.synced(keys, rows: now.rows, changed: fresh, sort: sort)
        }.value
        guard gen == generation, let after = pages[id] else { return }
        // An edit landed meanwhile: the rows it changed are taken again, here.
        if after.rows.count != now.rows.count || zip(after.rows, now.rows).contains(where: { $0 !== $1 }) {
            rows = Self.synced(keys, rows: after.rows, changed: fresh, sort: sort)
        }
        pages[id]!.rows = rows
        pages[id]!.fetched = rows.count
        pages[id]!.more = more
        pages[id]!.since = started
        show(merged(), animated: true)
        guard q.cache else { return }
        DiskCache.saveAsync(rows.map(\.issue), account: st.account, name: Self.wholeName(q.jql), asOf: started)
        Self.remember(rows.prefix(50).map(\.issue), jql: q.jql, state: st)
    }

    /// The keys of a list made of parts, in order, up to `cap`, and whether it runs past it.
    private static func keys(_ parts: [String], state: AccountState) async throws -> (keys: [String], more: Bool) {
        var keys: [String] = []
        for (n, part) in parts.enumerated() {
            let got = try await state.client.keys(jql: part, limit: cap - keys.count)
            keys += got.keys
            if got.more || keys.count >= cap { return (keys, got.more || n + 1 < parts.count) }
        }
        return (keys, false)
    }

    /// Every row `jql` matches for one account, up to `cap`, in pages of the largest the site serves.
    private static func all(_ jql: String, state: AccountState, cache: Bool) async throws -> [Issue] {
        var (issues, token) = ([Issue](), nil as String?)
        repeat {
            let page = try await fetch(
                jql: jql, state: state, nextPageToken: token, cache: cache, size: state.client.largestPage,
                remembers: false)
            issues += page.issues
            token = page.isLast == true ? nil : page.nextPageToken
        } while token != nil && issues.count < cap
        return issues
    }

    /// A list's query narrowed to the issues changed, or viewed on the web, in the last `minutes`, newest first.
    /// Relative dates are the server's own clock and zone.
    static func changed(_ jql: String, minutes: Int) -> String {
        let clause = jql.ranges(of: /(?i)\border\s+by\b/).last.map { jql[..<$0.lowerBound] } ?? jql[...]
        let recent = "(updated >= -\(minutes)m OR lastViewed >= -\(minutes)m)"
        let rest = clause.trimmingCharacters(in: .whitespaces)
        return (rest.isEmpty ? recent : "(\(rest)) AND \(recent)") + " ORDER BY updated DESC"
    }

    /// One account's rows brought up to date: `keys` in their order (the server's, each once), each the newest copy
    /// there is, a changed row's, else the row as it stands; a key neither has is left out. Rows that tie on the sort
    /// field keep the order they stand in, so a list sorted here reorders once, when Jira's order lands.
    nonisolated static func synced(_ keys: [String], rows: [ListRow], changed: [ListRow], sort: ListFilters.Sort)
        -> [ListRow]
    {
        var known = Dictionary(rows.map { ($0.issue.key, $0) }, uniquingKeysWith: { a, _ in a })
        for r in changed { known[r.issue.key] = r }
        var seen = Set<String>()
        var out = keys.compactMap { seen.insert($0).inserted ? known[$0] : nil }
        let place = Dictionary(rows.enumerated().map { ($1.issue.key, $0) }, uniquingKeysWith: { a, _ in a })
        // Each row's place as it stands, new ones last; already in that order (a refresh, mostly), nothing to keep.
        let at = out.map { place[$0.issue.key] ?? .max }
        let old = at.filter { $0 != .max }
        guard zip(old, old.dropFirst()).contains(where: { $0 > $1 }) else { return out }
        var i = 0
        while i < out.count {
            var j = i + 1
            while j < out.count, sort.compare(out[j - 1].issue, out[j].issue) == .orderedSame { j += 1 }
            if j - i > 1 {
                let run = (i..<j).sorted { (at[$0], $0) < (at[$1], $1) }.map { out[$0] }
                out.replaceSubrange(i..<j, with: run)
            }
            i = j
        }
        return out
    }

    /// Replaces the rows unless nothing changed: a refresh that brings the same page back must not redraw the list.
    /// `animated` for fresh rows replacing ones on screen: an edited issue glides to its new place, as in Mail,
    /// instead of every row jumping at once.
    private func show(_ new: [ListRow], animated: Bool = false, keep: Bool = true) {
        unshown = false
        let (new, stale) = Self.keeping(keep ? kept : [], of: rows, in: new)
        let gone = stale.subtracting(self.stale)
        if stale != self.stale { self.stale = stale }  // unchanged, nothing reading it redraws
        if !gone.isEmpty { Task { await refetch(gone) } }
        guard
            new.count != rows.count
                || zip(new, rows).contains(where: { $0 !== $1 && ($0.id != $1.id || $0.issue != $1.issue) })
        else { return }
        if animated, !rows.isEmpty {
            withAnimation(.smooth(duration: 0.35)) { rows = new }
        } else {
            rows = new
        }
    }

    /// The rows `ids` names, kept greyed though a reload no longer brings them (see `keeping`), as Jira has them now,
    /// by key: the edit that took them out of the list was the preview's (Issue › Change Status), which reaches no
    /// row, so the greyed row went on showing the issue from before it, "To Do" and "5 days ago" (CON-265).
    private func refetch(_ ids: Set<String>) async {
        for group in Dictionary(grouping: rows.filter { ids.contains($0.id) }, by: \.state.id).values {
            let st = group[0].state
            let keys = group.map { "\"\($0.issue.key)\"" }.joined(separator: ",")
            guard let page = try? await Self.fetch(jql: "issuekey in (\(keys))", state: st, cache: false) else {
                continue
            }
            let fresh = Dictionary(page.issues.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            edit({ $0.state === st && ids.contains($0.id) && fresh[$0.issue.key] != nil }) { $0 = fresh[$0.key]! }
        }
    }

    /// `new` with the rows of `old` that `kept` selects and `new` lacks, each after the row above it that `new` still
    /// has, and their ids.
    static func keeping(_ kept: Set<IssueTarget>, of old: [ListRow], in new: [ListRow]) -> ([ListRow], Set<String>) {
        var (new, stale) = (new, Set<String>())
        guard !kept.isEmpty else { return (new, stale) }
        var present = Set(new.map(\.id))
        for (i, r) in old.enumerated() where kept.contains(r.target) && !present.contains(r.id) {
            let above = old[..<i].last { present.contains($0.id) }
            new.insert(r, at: above.flatMap { a in new.firstIndex { $0.id == a.id } }.map { $0 + 1 } ?? 0)
            present.insert(r.id)
            stale.insert(r.id)
        }
        return (new, stale)
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

    /// The account the merge waits on: the one with more pages whose last row comes first. One whose rows already run
    /// to its end waits for nothing, so lists all whole merge as one plain sort.
    private var waiting: UUID? {
        pages.values.filter { $0.more && !$0.full }.min(by: {
            guard let a = $0.rows.last else { return true }
            guard let b = $1.rows.last else { return false }
            return sort.areInOrder(a.issue, b.issue)
        })?.state.id
    }

    /// The list's selection changed: a greyed row it left goes, the rows under it gliding up, as in Mail. A turn
    /// later, as the selection then stands, and both changes in the animation: called from the list's onChange, the
    /// removal landed in the selection's own pass, whose transaction has none, and the rows jumped up in one frame.
    func keep(_ selection: Set<IssueTarget>) {
        kept = selection
        guard !stale.isEmpty else { return }  // or each arrow press went through every row
        DispatchQueue.main.async { [self] in
            let gone = Set(rows.filter { stale.contains($0.id) && !kept.contains($0.target) }.map(\.id))
            guard !gone.isEmpty else { return }
            withAnimation(.smooth(duration: 0.35)) {
                stale.subtract(gone)
                rows.removeAll { gone.contains($0.id) }
            }
        }
    }

    /// The reader is near the end of the rows showing: the ones the whole list's load has fetched since (see `fill`)
    /// go on screen. End waits for the last row instead.
    func loadMore() {
        if unshown, !endPending { show(merged()) }
    }

    /// One account's next page into its `Page` and onto the screen. A page from the start replaces the rows it
    /// covers, and the rows of the last load below them stay until a fresh page reaches them: a reload (the app
    /// coming to the front, an edit, the timer) took a long list back to its first page, and a merged one to the
    /// few rows before the furthest-behind account's 50th, then grew it back under the reader. `first`: the list's
    /// first page, else the page after the last one fetched.
    private func fetchPage(_ id: UUID, gen: Int, first: Bool = false, size: Int = 50, shows: Bool = true) async throws {
        guard let q = query, let p = pages[id] else { return }
        let page = try await Self.pageWorth(
            q.parts, whole: q.jql, part: first ? 0 : p.part, token: first ? nil : p.token, state: p.state,
            cache: q.cache, size: size)
        // The rows as they are now: the whole list from disk can have landed under them meanwhile.
        guard gen == generation, let now = pages[id] else { return }
        let new = page.issues.map { ListRow(issue: $0, state: p.state) }
        let more = page.token != nil || page.part + 1 < q.parts.count
        if first, more, !now.full, now.fetched > new.count {
            // A download under way (an edit reloaded the list): the top is fresh at once, and the download goes on
            // from its own page rather than from the first again.
            pages[id]!.rows = Self.refreshed(now.rows, fetched: new, more: true)
        } else {
            // A row a page brings again (it moved down the list since the page above it came) counts once.
            let above = first ? [] : Array(now.rows.prefix(p.fetched))
            var ids = first ? [] : (now.fetched == p.fetched ? now.ids : nil) ?? Set(above.map(\.id))
            let fetched = above + new.filter { !ids.contains($0.id) }
            ids.formUnion(new.map(\.id))
            pages[id]!.rows = Self.refreshed(now.rows, fetched: fetched, more: more, keys: ids)
            pages[id]!.fetched = fetched.count
            pages[id]!.ids = ids
            (pages[id]!.part, pages[id]!.token) = (page.part, page.token)
            pages[id]!.more = more
        }
        if shows { show(merged(), animated: !isLoadingMore) } else { unshown = true }
        LaunchProbe.once("list.fresh")
    }

    /// One account's rows during a load: what it fetched so far, then the last load's rows from where those end,
    /// less any the fresh pages already hold; none once the list has no more. Each fresh row the old ones had only
    /// further down (an edited issue gone to the top) or never had pushes one of them past the page's end: that row
    /// stays too, or the row above an edited one vanished until the next page brought it back.
    /// `keys`: the ids of `fetched`, when the caller has them.
    static func refreshed(_ old: [ListRow], fetched: [ListRow], more: Bool, keys: Set<String>? = nil) -> [ListRow] {
        guard more else { return fetched }
        let keys = keys ?? Set(fetched.map(\.id))
        let covered = Set(old.prefix(fetched.count).map(\.id))
        let pushed = fetched.count { !covered.contains($0.id) }
        return fetched + old.dropFirst(fetched.count - pushed).filter { !keys.contains($0.id) }
    }

    private func fail(_ error: Error, cacheable: Bool) {
        guard !error.isOffline, !error.isCancelled else { return }
        // A 400 on a typed search is the query itself; an alert would steal the keystrokes that fix it.
        if !cacheable, (error as? JiraError)?.status == 400 {
            queryError = error.localizedDescription
            rows = []
            stale = []
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
    @State private var store = IssueListStore()
    @State private var suggestions: [(display: String, completion: String)] = []
    @State private var savingFilter = false
    @State private var filterName = ""
    @State private var chipMenus = ChipMenuController()
    /// The project's assignable people, by name: the Assignee chip's people where the site hides its own.
    @State private var assignable: [JiraUser] = []
    /// The chip Choose person… was picked under, which its picker hangs from: Assignee, or Filter while it is unset.
    @State private var choosingUnder: String?
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
    /// The chip strip's height: the rows start under it, and scroll under it.
    @State private var chipsHeight: CGFloat = 0
    private var displayRows: [DisplayRow] { store.displayRows(expanded: expanded) }

    /// The account the chips describe; the first one stands in for unified lists (search assist, issue types).
    private var state: AccountState? {
        filters.account.flatMap(session.state) ?? session.states.first { filters.includes($0.id) }
            ?? session.states.first
    }
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
    /// and the sort order stay. It shows only once the chips differ from that. `preset`: the one the list came from.
    private func cleared(_ preset: Preset?) -> ListFilters {
        var f = preset?.filters ?? ListFilters()
        f.account = filters.account
        f.project = filters.project
        f.text = filters.text
        f.sort = filters.sort
        return f
    }

    var body: some View {
        let _ = LaunchProbe.tick("list.body")
        // The sidebar entry the list came from, found here once a pass (and by `title(for:)` once more): each look
        // builds every entry of every account, reading the Hide Done default for each, and the title, the clear
        // button and Save Filter looked six times on every arrow press.
        let preset = session.preset(matching: filters)
        let cleared = self.cleared(preset)
        let canSave = canSaveFilter(preset)
        let title = session.title(for: filters)
        IssueRows(
            store: store, selection: $selection, expanded: $expanded,
            previewFocused: $previewFocused, subtitle: $shownSubtitle, chips: chipsHeight,
            menu: { targets in
                // Over a selected row the menu acts on the whole selection, else on the row under the pointer.
                let rows = store.rows.filter { targets.contains($0.target) }
                guard let state = rows.first?.state, rows.allSatisfy({ $0.state === state }) else { return nil }
                return NSHostingMenu(
                    rootView: IssueMenu(
                        issues: rows.map(\.issue), state: state, write: { act(keys: rows.map(\.issue.key), $0) },
                        patch: store.patch
                    )
                    // Titles alone, as the List's context menu had: a hosting menu draws the icons too.
                    .labelStyle(.titleOnly)
                    .environment(session))
            },
            open: { targets in
                // Double-click, ↩ or Space moves the issue to a window of its own, like a message in Mail: the preview
                // lets it go, so the same page is never open twice.
                for t in targets { openWindow(id: "issue", value: t) }
                opened = targets.first
                selection = []
            },
            key: listKey
        )
        .modifier(FollowsOtherWindows(store: store, selection: $selection, opened: $opened))
        .safeAreaInset(edge: .top, spacing: 0) {
            chips(cleared: cleared).onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                chipsHeight = $0
            }
        }
        .overlay { ListOverlay(store: store, filters: $filters, cleared: cleared) }
        .focusedSceneValue(
            \.listActions,
            ListActions(
                saveFilter: canSave
                    ? {
                        filterName = ""
                        savingFilter = true
                    } : nil,
                openBoard: boardTarget.map { b in { openWindow(id: "board", value: b) } },
                sort: $filters.sort
            )
        )
        .navigationTitle(title)  // the Window menu; the toolbar draws its own, with the sort
        .toolbar(removing: .title)
        .background(ToolbarRelayout())
        .searchable(text: $filters.text, placement: .toolbar, prompt: "Search, JQL, or paste a Jira link")
        // A prompt wider than the field (German, or the window at its 1100 pt minimum) ends in "…" rather than being
        // cut mid-word (CON-270): the toolbar field takes its line break mode from outside `.searchable`, and keeps it
        // as SwiftUI updates it. Text truncates at the tail anyway, and the rows are hosted apart, so nothing else
        // changes.
        .truncationMode(.tail)
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
            if let st = session.state(host: url.host() ?? ""), filters.account != st.id { setAccounts([st.id]) }
            filters.text = key
            // A turn later: the main window drops the selection when the account changes, and this lands after it.
            DispatchQueue.main.async { openKey() }
        }
        .toolbar(id: "list") {
            ToolbarItem(id: "title") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
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
                    // Only what moves the column's minimum: each write runs the whole window's body again.
                    if max(420, $0 + 150) != max(420, titleWidth + 150) { titleWidth = $0 }
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
                .disabled(!canSave)
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
            // The issue of a key search that found nothing (`QA-9999` ↩) was never a row: it goes with the search, or
            // the preview went on saying "Can't find" over the list the search gave back (CON-268). A key it found is
            // a row and stays, as an issue picked before the search does (see `RootView`'s onChange of the filters).
            let key = old.text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if old.isKey, new.text.isEmpty, !selection.isEmpty, selection.allSatisfy({ $0.key == key }),
                !store.rows.contains(where: { selection.contains($0.target) })
            {
                selection = []
            }
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
            store.keep(new)
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
                    suggestions.isEmpty, let first = displayRows.first?.row.target
                else { return e }
                if selection.isEmpty { selection = [first] }
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
        let owners = session.states.filter { filters.includes($0.id) }.filter {
            $0.projects.contains { $0.key == project }
        }
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

    /// The keys the list acts on before its table: ↓ and ↑ (see `step`), → and ← (see `sideways`), and Space, which
    /// opens the selection as ↩ and a double-click do. True when one acted.
    private func listKey(_ e: NSEvent) -> Bool {
        switch e.keyCode {
        case 125, 126:
            let plain = e.modifierFlags.intersection([.shift, .option, .command, .control]).isEmpty
            return step(by: e.keyCode == 125 ? 1 : -1, plain: plain, repeating: e.isARepeat)
        // → unfolds a parent's subtasks; with nothing to unfold it moves the keyboard into the preview, whose ←
        // brings it back (the other way round right to left).
        case 124: return sideways(towardPreview: layoutDirection == .leftToRight)
        case 123: return sideways(towardPreview: layoutDirection == .rightToLeft)
        case 49:
            guard !selection.isEmpty else { return false }
            for t in selection { openWindow(id: "issue", value: t) }
            opened = selection.first
            selection = []
            return true
        default: return false
        }
    }

    /// A plain ↓ or ↑ steps from the one selected row, or, back from an issue opened in its own window, from that
    /// issue rather than the top of the list. Here, not in the table: the selection reaches the table a pass late,
    /// and steps the table took in between were undone. Shift and the other arrows stay the table's, as does a
    /// multi-selection.
    private func step(by delta: Int, plain: Bool, repeating: Bool) -> Bool {
        let shown = displayRows  // not the body's: a held key reaching the end goes on into the next page
        let current = cursor.map { [$0] } ?? selection
        guard let row = current.isEmpty ? opened : (plain && current.count == 1 ? current.first : nil),
            let i = shown.firstIndex(where: { $0.row.target == row })
        else { return false }
        let target = shown[max(0, min(shown.count - 1, i + delta))].row.target
        let from = shown[i].row.target
        selection = [target]
        cursor = target
        opened = nil
        // The list glides after the row with room to spare, for as long as the arrows stay on it, finding it again
        // each time. A held key moves at once: a glide begun again on every repeat lagged rows behind the selection.
        if let table = NSApp.keyWindow?.contentView.flatMap(firstTable), let sv = table.enclosingScrollView {
            sv.reveal(
                {
                    let rows = displayRows
                    guard cursor == target, let j = rows.firstIndex(where: { $0.row.target == target }),
                        j < table.numberOfRows
                    else { return nil }
                    // The row it left too, while beside it: after an edit sent that row to the top, ↓ goes to the top.
                    var r = table.rect(ofRow: j)
                    if let k = rows.firstIndex(where: { $0.row.target == from }), abs(k - j) == 1,
                        k < table.numberOfRows
                    {
                        r = r.union(table.rect(ofRow: k))
                    }
                    return sv.contentView.convert(r, from: table)
                }, room: 12, animated: !repeating)
        }
        return true
    }

    private func sideways(towardPreview: Bool) -> Bool {
        fold(open: towardPreview)
            || (towardPreview && selection.count == 1 && NSApp.keyWindow?.focusPreviewPage() == true)
    }

    /// → unfolds the selected parent's subtasks, ← folds them, as in an outline (the other way round right to left).
    /// ← on a subtask goes to its parent, as in the Finder's list view, and the next ← folds it. The row is the one
    /// `step` moves from: `selection` reads as of the pass that made this handler.
    private func fold(open: Bool) -> Bool {
        let current = cursor.map { [$0] } ?? selection
        let rows = displayRows
        guard current.count == 1, let sel = current.first, let i = rows.firstIndex(where: { $0.row.target == sel })
        else { return false }
        let d = rows[i]
        if !d.children.isEmpty, expanded.contains(d.id) != open {
            withAnimation(.snappy(duration: 0.25)) { expanded.formSymmetricDifference([d.id]) }
            return true
        }
        // Subtasks follow their parent (see `DisplayRow.nest`): it is the nearest row above that sits less deep.
        guard !open, d.depth > 0, let p = rows[..<i].lastIndex(where: { $0.depth < d.depth }) else { return false }
        return step(by: p - i, plain: true, repeating: false)
    }

    /// There is something to save once the list differs from every sidebar entry, built-in, saved or project.
    /// `preset`: the one the list came from.
    private func canSaveFilter(_ preset: Preset?) -> Bool {
        guard filters.isActive else { return false }
        if !filters.text.isEmpty { return true }
        var projectRow = ListFilters()
        projectRow.account = filters.account
        projectRow.project = filters.project
        // A few accounts picked on an All Accounts entry still light it up, but make a list of their own.
        return (preset.map { $0.filters.accounts != filters.accounts } ?? true)
            && filters != projectRow
    }

    private var boardTarget: BoardTarget? {
        guard let id = filters.account, let key = filters.project else { return nil }
        return BoardTarget(accountID: id, projectKey: key)
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

    /// One account is its own sidebar section; a few stay a unified list; all of them is the plain one.
    private func setAccounts(_ ids: Set<UUID>) {
        let all = session.states.allSatisfy { ids.contains($0.id) }
        filters.account = ids.count == 1 ? ids.first : nil
        filters.accounts = all || ids.count == 1 ? nil : ids
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
        /// Made when the menu opens: the list's body runs on every arrow press, and the Assignee chip's items ran to
        /// 500 people, an item and a closure each, every time.
        let items: () -> [ChipItem]
        init(id: String, name: String, title: String, active: Bool, items: @autoclosure @escaping () -> [ChipItem]) {
            (self.id, self.name, self.title, self.active, self.items) = (id, name, title, active, items)
        }
    }

    /// The people the Assignee chip offers inside one account: the site's, else, where the site hides them, the
    /// project's assignable ones; none in a list of several accounts, since ids belong to one site.
    private var people: [JiraUser] {
        let everyone = filters.account.flatMap(session.state)?.people?.users ?? []
        return everyone.isEmpty ? assignable : everyone
    }

    /// Up to this many people the Assignee chip's menu names them all; a menu of thousands is unusable.
    static let peopleInMenu = 500

    /// What the Assignee chip lists after its built-ins: everyone up to `peopleInMenu`, past it only Choose person…,
    /// which searches them all. The chosen person is listed whatever the count, even one no longer among the people,
    /// so the check mark always shows whom the chip filters by.
    static func assigneeMenu(_ people: [JiraUser], chosen: ListFilters.Person?) -> (
        listed: [ListFilters.Person], picker: Bool
    ) {
        let picker = people.count > peopleInMenu
        let listed = picker ? [] : people.map { ListFilters.Person(id: $0.accountId, name: $0.displayName) }
        guard let chosen, !listed.contains(where: { $0.id == chosen.id }) else { return (listed, picker) }
        return ([chosen] + listed, picker)
    }

    /// True while Choose person…'s picker hangs from the chip `id`.
    private func choosing(_ id: String) -> Binding<Bool> {
        Binding(get: { choosingUnder == id }, set: { if !$0 { choosingUnder = nil } })
    }

    /// Choose person…'s picker: the chip's people, searched on this Mac as you type.
    private var personPicker: some View {
        PeoplePicker(scope: .people(people), current: nil) { u in
            choosingUnder = nil
            guard let u else { return }
            filters.assignee = .any
            filters.assignedTo = .init(id: u.accountId, name: u.displayName)
        }
    }

    private var chipList: [Chip] {
        var list: [Chip] = []
        if session.states.count > 1 {
            // Checkboxes: each account goes in or out of the list, never the last one; All accounts checks them all.
            let picked = Set(session.states.map(\.id).filter(filters.includes))
            list.append(
                Chip(
                    id: "account", name: String(localized: "Account"),
                    title: picked.count == 1
                        ? session.states.first { picked.contains($0.id) }?.title ?? ""
                        : picked.count < session.states.count
                            ? String(
                                localized: "\(picked.count) accounts",
                                comment: "Account filter chip: some of the signed-in accounts")
                            : String(localized: "All accounts"),
                    active: picked.count < session.states.count,
                    items: [
                        ChipItem(String(localized: "All accounts"), selected: false) {
                            setAccounts(Set(session.states.map(\.id)))
                        }, .separator,
                    ]
                        + session.states.map { st in
                            ChipItem(st.title, selected: picked.contains(st.id)) {
                                let ids = picked.symmetricDifference([st.id])
                                if !ids.isEmpty { setAccounts(ids) }
                            }
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
        let assigneeSet = filters.assignee != .any || filters.assignedTo != nil
        list.append(
            Chip(
                id: "assignee", name: String(localized: "Assignee"),
                title: filters.assignedTo?.name ?? filters.assignee.title,
                active: assigneeSet,
                items: assigneeItems(set: assigneeSet)))
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

    /// The Assignee chip's menu: its built-ins, then its people (see `assigneeMenu`). `set`: the chip filters, so
    /// Choose person…'s picker hangs from it rather than from Filter.
    private func assigneeItems(set: Bool) -> [ChipItem] {
        let menu = Self.assigneeMenu(people, chosen: filters.assignedTo)
        return ListFilters.Assignee.allCases.map { a in
            ChipItem(a.title, selected: filters.assignedTo == nil && filters.assignee == a) {
                filters.assignee = a
                filters.assignedTo = nil
            }
        }
            + (menu.listed.isEmpty && !menu.picker ? [] : [ChipItem.separator])
            + menu.listed.map { p in
                ChipItem(p.name, selected: filters.assignedTo?.id == p.id) {
                    filters.assignee = .any
                    filters.assignedTo = p
                }
            }
            + (menu.picker
                ? [
                    ChipItem(String(localized: "Choose person…"), selected: false) {
                        choosingUnder = set ? "assignee" : "add"
                    }
                ] : [])
    }

    /// Only the filters that are set get a chip; the rest wait under one Filter chip, so the column stays narrow.
    private func chips(cleared: ListFilters) -> some View {
        let all = chipList
        let more = all.filter { !$0.active }
        // A key or raw JQL ignores the chips: they go grey like an inactive window's, still legible.
        let muted = filters.isRawJQL || filters.isKey
        return HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(all.filter(\.active), id: \.id) { c in
                        FilterChip(
                            id: c.id, title: c.title, active: true, enabled: !muted, menus: chipMenus, items: c.items
                        )
                        .popover(isPresented: choosing(c.id), arrowEdge: .bottom) { personPicker }
                    }
                    if !more.isEmpty {
                        FilterChip(
                            id: "add", title: String(localized: "Filter"), symbol: "plus", active: false,
                            menus: chipMenus,
                            items: { more.map { ChipItem($0.name, children: $0.items()) } }
                        )
                        .help("Add a filter")
                        .popover(isPresented: choosing("add"), arrowEdge: .bottom) { personPicker }
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
        // Inside one project of a site that hides its people, the ones the assignee picker keeps: the cached list at
        // once, the fresh one behind.
        .task(id: [filters.account?.uuidString, filters.project]) {
            assignable = []
            guard let st = filters.account.flatMap(session.state), let key = filters.project,
                st.people?.users.isEmpty ?? true
            else { return }
            let c = st.client
            let byName = { (l: [JiraUser]) in
                l.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            }
            let (now, fresh) = st.memo("assignable-\(key)") { try await c.assignableUsers(project: key, query: "") }
            assignable = byName(now ?? [])
            if let list = await fresh.value, !Task.isCancelled { assignable = byName(list) }
        }
        .help(
            filters.isRawJQL
                ? "Filters don't apply to raw JQL" : filters.isKey ? "A key opens that issue whatever the filters" : "")
    }

    // MARK: Search assist

    /// The five newest issues in memory whose key starts with `needle` or whose summary holds it, a key once. Kept
    /// as it goes, with no copy of every issue and no sort of every match: it runs on each keystroke.
    static func newestKnown(matching needle: String, in states: [AccountState]) -> [Issue] {
        let key = needle.uppercased()
        var (seen, top) = (Set<String>(), [Issue]())
        for st in states {
            for i in st.peek.values
            where seen.insert(i.key).inserted
                && (i.key.hasPrefix(key) || i.fields.summary.localizedCaseInsensitiveContains(needle))
            {
                let updated = i.fields.updated ?? .distantPast
                let at = top.firstIndex { ($0.fields.updated ?? .distantPast) < updated } ?? top.endIndex
                guard at < 5 else { continue }
                top.insert(i, at: at)
                if top.count > 5 { top.removeLast() }
            }
        }
        return top
    }

    private func updateSuggestions() async {
        let q = filters.text
        if q.isEmpty {
            suggestions = session.recentSearches.map { ($0, $0) }
            return
        }
        // Issues the app has seen whose key or summary matches, newest first: picking one puts its key in the
        // field, and ↩ opens it. Raw JQL gets the field and value help below instead.
        if !filters.isRawJQL {
            let hits = Self.newestKnown(matching: q.trimmingCharacters(in: .whitespaces), in: session.states)
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

/// The rows and what reads them. A view of its own, so a page landing redraws the table, not the list's toolbar,
/// chips and search around it.
private struct IssueRows: View {
    let store: IssueListStore
    @Binding var selection: Set<IssueTarget>
    @Binding var expanded: Set<String>
    @Binding var previewFocused: Bool
    /// The toolbar's count, kept as it changes.
    @Binding var subtitle: String
    let chips: CGFloat
    let menu: (Set<IssueTarget>) -> NSMenu?
    let open: (Set<IssueTarget>) -> Void
    let key: (NSEvent) -> Bool
    @Environment(Session.self) private var session
    @Environment(\.appearsActive) private var active

    /// The issues the query matches (the server's count, or the rows once all are loaded); "50+" only while no
    /// count is known. Nil while a list loads with nothing to show yet.
    private var count: String? {
        store.rows.isEmpty && store.total == nil && store.isLoading
            ? nil : issues(store.count, more: store.total == nil && store.hasMore)
    }

    var body: some View {
        let shown = store.displayRows(expanded: expanded)
        // As the list the rows are of, until another list's rows land.
        let of = store.shown
        let _ = LaunchProbe.once("list.rows", when: !shown.isEmpty)
        // Only a multi-selection has links to copy: a pass over every row for each arrow press was for nothing.
        let picked = selection.count > 1 ? shown.map(\.row).filter { selection.contains($0.target) } : []
        IssueTable(
            rows: shown,
            // The spinner only while there is nothing to show, or rows are still to come under the last one on screen
            // or under a waiting End: a refresh behind rows that are already on screen must not add and remove a row
            // at the end of the list.
            footer: store.isLoading
                ? (store.rows.isEmpty
                    || (!store.complete
                        && (store.endPending || store.isLoadingMore && store.lastShown == shown.last?.id))
                    ? .spinner : nil)
                : of.scope == .recent && !store.rows.isEmpty ? .caption : nil,
            selection: $selection,
            chips: chips,
            content: { i in
                let d = shown[i]
                let row = d.row
                let selected = selection.contains(row.target)
                return ListRowView(
                    d: d, site: of.account == nil && session.states.count > 1, sort: of.sort,
                    selected: selected, emphasized: selected && active && !previewFocused,
                    above: i > 0 && selection.contains(shown[i - 1].row.target),
                    below: i + 1 < shown.count && selection.contains(shown[i + 1].row.target),
                    expanded: expanded.contains(d.id), pending: store.pending.contains(row.issue.key),
                    stale: store.stale.contains(row.id), tips: store.hovered == d.id,
                    toggle: d.children.isEmpty
                        ? nil : { withAnimation(.snappy(duration: 0.25)) { expanded.formSymmetricDifference([d.id]) } }
                )
            },
            session: session, menu: menu, open: open, key: key,
            lastShown: { id in
                // On screen, the last row takes the rows fetched since, if the scroll has not already, and the
                // spinner shows while more are on their way.
                Task {
                    if store.lastShown != id { store.lastShown = id }
                    store.loadMore()
                }
            },
            complete: store.complete, toCome: store.toCome, pinEnd: store.endPending,
            waitForEnd: { wait in if store.endPending != wait { store.endPending = wait && !store.complete } },
            list: store.shownKey
        )
        // Under the toolbar, the chips and the sidebar, as the List lay: its insets keep the rows clear of them.
        .ignoresSafeArea()
        // VoiceOver's frame for the list is the part clear of them, as the List's was; SwiftUI sets it, not the table.
        .contentShape(.accessibility, Rectangle())
        .background(
            NativeSelectionOff(
                previewFocused: $previewFocused,
                hover: { i in
                    let id = i.flatMap { $0 < shown.count ? shown[$0].id : nil }
                    if store.hovered != id { store.hovered = id }
                },
                // Ten rows before the end, so the rows fetched since are in before the reader gets there.
                nearEnd: { if store.hasMore { Task { store.loadMore() } } }
            )
        )
        .focusedSceneValue(
            \.selectedLinks, picked.count > 1 ? picked.map { $0.state.client.browseURL($0.issue.key) } : nil
        )
        .onChange(of: count, initial: true) { _, s in if let s { subtitle = s } }
    }
}

/// What the list says in place of rows: no filter, a query Jira refused, or nothing found.
private struct ListOverlay: View {
    let store: IssueListStore
    @Binding var filters: ListFilters
    let cleared: ListFilters

    var body: some View {
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

/// A list row and what the list knows about it. A view of its own, compared as a value, so an update leaves the rows
/// it did not change be.
struct ListRowView: View, Equatable {
    let d: DisplayRow
    /// The account tag shows: a list of several accounts.
    let site: Bool
    let sort: ListFilters.Sort
    // The open issue stays in the accent colour while the window is active, as in Notes and Mail; behind another
    // window it goes grey like any selection. A run of selected rows is one block, rounded at its ends only, as Mail
    // paints it: `above` and `below` say whether the neighbours are selected too.
    let selected: Bool
    let emphasized: Bool
    let above: Bool
    let below: Bool
    let expanded: Bool
    let pending: Bool
    /// Out of this list since the last reload.
    let stale: Bool
    /// Under the pointer: the one row with tooltips (see `help(_:tips:)`).
    let tips: Bool
    /// Not compared: it only flips `expanded`, which is, and it is there exactly when `d` has children.
    let toggle: (() -> Void)?

    nonisolated static func == (a: Self, b: Self) -> Bool {
        // The same row is the same issue (a `ListRow` never changes): no whole issue compared for each row shown, on
        // every update.
        (a.d.row === b.d.row || a.d.row.issue == b.d.row.issue && a.d.row.state === b.d.row.state)
            && a.d.depth == b.d.depth
            && a.d.children.count == b.d.children.count && a.site == b.site && a.sort == b.sort
            && a.selected == b.selected && a.emphasized == b.emphasized && a.above == b.above && a.below == b.below
            && a.expanded == b.expanded && a.pending == b.pending && a.stale == b.stale && a.tips == b.tips
    }

    var body: some View {
        let row = d.row
        IssueRow(
            issue: row.issue, site: site ? (row.state.title, row.state.color) : nil, date: sort.date(of: row.issue),
            dayOnly: sort.field == .due, depth: d.depth, folded: d.children.count, expanded: expanded, toggle: toggle,
            pending: pending, tips: tips
        )
        .opacity(stale ? 0.45 : 1)
        // The table's own highlight, grey without focus, is off: the rows paint theirs.
        .foregroundStyle(emphasized ? AnyShapeStyle(.white) : AnyShapeStyle(.foreground))
        .environment(\.backgroundProminence, emphasized ? .increased : .standard)
    }

    /// Behind the whole row, over its full width.
    var selectionBlock: some View {
        let corner: CGFloat = selected ? 6 : 0
        return UnevenRoundedRectangle(
            topLeadingRadius: above ? 0 : corner, bottomLeadingRadius: below ? 0 : corner,
            bottomTrailingRadius: below ? 0 : corner, topTrailingRadius: above ? 0 : corner
        )
        // Unselected rows in the table's own colour over the whole row, not clear or inset: a row gliding
        // to its new place passes over the others, or under them for its first frame, and see-through it
        // drew its text over theirs, inset its corners showed round theirs.
        .fill(
            emphasized
                ? Color.accentColor
                : selected
                    ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
                    : Color(nsColor: .controlBackgroundColor)
        )
        // 10, not 8: the ring AppKit draws around right-clicked rows then runs 1 pt inside this block on
        // every side, as Mail's does; at 8 it sat 3 pt in at the sides and 1 pt at the top and bottom.
        .padding(.horizontal, selected ? 10 : 0)
        // Over the row gap, so two selected rows meet without a seam.
        .padding(.top, selected && above ? -3 : 0).padding(.bottom, selected && below ? -3 : 0)
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
    /// Tooltips on the icons, the date and the chevron: the list gives them to the row under the pointer alone.
    var tips = true
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
                .help(Text(issue.fields.issuetype.name), tips: tips)
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
                                Text(
                                    dayOnly
                                        ? date.formatted(date: .long, time: .omitted)
                                        : date.formatted(date: .abbreviated, time: .shortened)), tips: tips)
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
                        .help(Text(expanded ? "Hide subtasks" : "Show \(folded) subtasks from this list"), tips: tips)
                    }
                    Spacer(minLength: 0)
                    if let p = issue.fields.priority { PriorityIcon(priority: p, tips: tips) }
                    Avatar(user: issue.fields.assignee, size: 18, tips: tips)
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
    /// Each chip's items, made as its menu opens.
    private var items: [String: () -> [ChipItem]] = [:]
    private var openID: String?
    private var actions: [NSMenuItem: () -> Void] = [:]

    func register(_ id: String, view: NSView, items: @escaping () -> [ChipItem]) {
        anchors[id] = view
        self.items[id] = items
    }

    func toggle(_ id: String) {
        if openID == id { return }  // the click that closed it must not reopen it
        open(id)
    }

    private func open(_ id: String) {
        guard let anchor = anchors[id], let list = items[id]?() else { return }
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
    let items: () -> [ChipItem]
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
    /// The row under the pointer, by index, nil off the rows: the one row with tooltips (see `help(_:tips:)`).
    var hover: ((Int?) -> Void)?
    /// The scroll has brought one of the last ten rows on screen. From the scroll, not a row's appearance: the
    /// table also makes rows it does not show (to measure them, for accessibility), and those loaded pages nobody
    /// had scrolled to.
    var nearEnd: (() -> Void)?
    func makeNSView(context: Context) -> Finder { Finder() }
    func updateNSView(_ view: Finder, context: Context) {
        view.previewFocused = previewFocused
        view.hover = hover
        view.nearEnd = nearEnd
    }
    final class Finder: NSView {
        var previewFocused: Binding<Bool>?
        var hover: ((Int?) -> Void)?
        var nearEnd: (() -> Void)?
        private weak var table: NSTableView?
        nonisolated(unsafe) private var monitor: Any?
        nonisolated(unsafe) private var observer: Any?
        nonisolated(unsafe) private var scrollEnd: Any?
        nonisolated(unsafe) private var scrolled: Any?
        override func viewDidMoveToWindow() { find(attempt: 0) }
        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            for o in [observer, scrollEnd, scrolled] { if let o { NotificationCenter.default.removeObserver(o) } }
        }

        // Moves of the pointer alone: a scroll under a resting pointer leaves the tooltips where they were until it
        // ends. One tracking area over the list, this view's own, where every tooltip was one.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if trackingAreas.isEmpty {
                addTrackingArea(
                    NSTrackingArea(
                        rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                        owner: self))
            }
        }
        override func mouseEntered(with event: NSEvent) { pointerMoved() }
        override func mouseMoved(with event: NSEvent) { pointerMoved() }
        override func mouseExited(with event: NSEvent) { hovered(nil) }

        private func pointerMoved() {
            guard let table, let window = table.window else { return }
            let p = table.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            let row = table.visibleRect.contains(p) ? table.row(at: p) : -1
            hovered(row >= 0 ? row : nil)
        }

        /// The list learns the row under the pointer first, then the table shows the row it left and the one it is on
        /// again, the tooltips moved.
        private func hovered(_ row: Int?) {
            hover?(row)
            (table as? IssueOutline)?.coordinator?.hover(row)
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
                    let sv = table.enclosingScrollView
                else { return e }
                // End on a list loaded whole goes to its true end, waiting for its last rows if need be.
                if (table as? IssueOutline)?.coordinator?.endKey(e) == true { return nil }
                return sv.scrollAnimated(for: e, line: 0, arrows: false) ? nil : e
            }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = NotificationCenter.default.addObserver(
                forName: .previewFocus, object: table.window, queue: .main
            ) { [weak self] n in
                let on = n.userInfo?["on"] as? Bool ?? false
                MainActor.assumeIsolated { self?.previewFocused?.wrappedValue = on }
            }
            self.table = table
            if let scrollEnd { NotificationCenter.default.removeObserver(scrollEnd) }
            scrollEnd = NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification, object: table.enclosingScrollView, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.pointerMoved() } }
            if let scrolled { NotificationCenter.default.removeObserver(scrolled) }
            scrolled = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: table.enclosingScrollView?.contentView, queue: nil
            ) { [weak self, weak table] _ in
                MainActor.assumeIsolated {
                    guard let table, NSMaxRange(table.rows(in: table.visibleRect)) >= table.numberOfRows - 10 else {
                        return
                    }
                    self?.nearEnd?()
                }
            }
        }
    }
}

/// Transparent view that gives the chip an NSView to anchor its menu to.
private struct ChipAnchor: NSViewRepresentable {
    let id: String
    let menus: ChipMenuController
    let items: () -> [ChipItem]
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
