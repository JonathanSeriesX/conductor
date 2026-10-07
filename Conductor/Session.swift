import SwiftUI

/// An issue plus the account it lives in. Keys alone are ambiguous once several sites are signed in.
struct IssueTarget: Hashable, Codable, Sendable {
    let accountID: UUID
    let key: String
}

/// Everything that belongs to one signed-in account. Every account stays live; there is no "current" one.
@MainActor @Observable
final class AccountState: Identifiable {
    let account: Account
    var client: JiraClient
    var me: JiraUser?
    var projects: [Project] = []
    var filters: [Filter] = []
    var starred: Set<String> = []
    var issueTypeNames: [String] = []
    var jqlFields: [JQLAutocomplete.Field] = []
    /// Set when the last network check failed; the cached catalog stays usable.
    var error: String?
    /// Rows the lists have seen, so an issue page can open with what the row already knows.
    @ObservationIgnored var peek: [String: Issue] = [:]
    @ObservationIgnored private var linkTypesCache: [LinkType]?
    @ObservationIgnored private var sprintsByProject: [String: [Sprint]] = [:]
    private var customTitle: String
    /// Name of a `Palette` colour; chosen by the user or dealt from the palette by sidebar position.
    var colorName: String

    var color: Color { Palette.color(named: colorName) }

    nonisolated var id: UUID { account.id }
    var host: String { account.site.host() ?? "" }
    /// The user's own name for the account, else the company from the email domain ("acme.com" → "Acme"),
    /// else the site's first label. Jira's own site title is just "Jira" on most sites.
    var title: String {
        if !customTitle.isEmpty { return customTitle }
        let publicMail: Set<String> = ["gmail", "icloud", "me", "outlook", "hotmail", "live", "yahoo", "proton", "protonmail", "fastmail", "hey"]
        let domain = account.email.split(separator: "@").last.map(String.init) ?? ""
        var label = domain.split(separator: ".").dropLast().last.map(String.init) ?? ""
        if label.isEmpty || publicMail.contains(label.lowercased()) { label = host.split(separator: ".").first.map(String.init) ?? host }
        return label.prefix(1).uppercased() + label.dropFirst()
    }
    var starredProjects: [Project] { projects.filter { starred.contains($0.key) } }
    /// `updated` of each issue whose full details were prefetched to disk, so unchanged ones are skipped.
    var prefetched: [String: Date] = [:]

    init(account: Account) {
        self.account = account
        client = JiraClient(account: account)
        customTitle = UserDefaults.standard.string(forKey: "accountTitle.\(account.id)") ?? ""
        colorName = UserDefaults.standard.string(forKey: "accountColor.\(account.id)") ?? ""
    }

    func setColor(_ name: String) {
        colorName = name
        UserDefaults.standard.set(name, forKey: "accountColor.\(id)")
    }

    /// Everything the last session knew, read from disk. True when enough is there to show the account at once.
    func loadCached() -> Bool {
        me = DiskCache.load(account: account, name: "me")
        client.sprintField = DiskCache.load(account: account, name: "sprintField")
        client.pointsFields = DiskCache.load(account: account, name: "pointsFields") ?? []
        projects = DiskCache.load(account: account, name: "projects") ?? []
        filters = DiskCache.load(account: account, name: "filters") ?? []
        issueTypeNames = DiskCache.load(account: account, name: "issueTypes") ?? []
        jqlFields = DiskCache.load(account: account, name: "jqlFields") ?? []
        starred = Set(projects.filter { $0.favourite == true }.map(\.key))
        return me != nil
    }

    /// Validates the token and refreshes the catalog, all requests in flight together.
    func load() async throws {
        async let user = client.myself()
        async let custom = client.customFieldIds()
        async let catalog: () = refreshCatalog()
        me = try await user
        DiskCache.saveAsync(me, account: account, name: "me")
        if let ids = try? await custom {
            client.sprintField = ids.sprint
            client.pointsFields = ids.points
            DiskCache.saveAsync(ids.sprint, account: account, name: "sprintField")
            DiskCache.saveAsync(ids.points, account: account, name: "pointsFields")
        }
        await catalog
        error = nil
        await prefetchLists()
    }

    func refreshCatalog() async {
        async let p = client.projects()
        async let f = client.favouriteFilters()
        async let t = client.issueTypes()
        async let a = client.jqlAutocomplete()
        if let fresh = try? await p { projects = fresh; DiskCache.saveAsync(fresh, account: account, name: "projects") }
        if let fresh = try? await f { filters = fresh; DiskCache.saveAsync(fresh, account: account, name: "filters") }
        starred = Set(projects.filter { $0.favourite == true }.map(\.key))
        if let fresh = try? await t {
            issueTypeNames = Array(Set(fresh.map(\.name))).sorted()
            DiskCache.saveAsync(issueTypeNames, account: account, name: "issueTypes")
        }
        if let fresh = try? await a {
            jqlFields = fresh.visibleFieldNames
            DiskCache.saveAsync(jqlFields, account: account, name: "jqlFields")
        }
    }

    /// Warms every smart list so each sidebar shortcut opens from disk, and the unified lists with it.
    func prefetchLists() async {
        let tasks = Smart.allCases.filter { $0 != .starred }.map { smart in
            let jql = smart.filters(account: id).jql()
            return Task { @MainActor in
                guard let page = try? await IssueListStore.fetch(jql: jql, state: self, cache: true) else { return }
                if smart == .assigned { IssueListStore.prefetchDetails(page.issues.map { ListRow(issue: $0, state: self) }) }
            }
        }
        for t in tasks { await t.value }
        // Starred projects' boards next, one at a time: a board is three or four requests and they should
        // not compete with the lists that are on screen.
        for p in starredProjects { await BoardStore.prefetch(p.key, state: self) }
    }

    func linkTypes() async -> [LinkType] {
        if let linkTypesCache { return linkTypesCache }
        let fresh = (try? await client.linkTypes()) ?? []
        if !fresh.isEmpty { linkTypesCache = fresh }
        return fresh
    }

    /// Active and future sprints of a project's scrum boards, fetched once per session.
    func sprints(project: String) async -> [Sprint] {
        if let cached = sprintsByProject[project] { return cached }
        guard let boards = try? await client.boards(project: project) else { return [] }
        let tasks = boards.filter { $0.type == "scrum" }.map { b in Task { @MainActor in (try? await self.client.sprints(board: b.id)) ?? [] } }
        var all: [Sprint] = []
        for t in tasks { all += await t.value }
        var seen = Set<Int>()
        let unique = all.filter { seen.insert($0.id).inserted }
        sprintsByProject[project] = unique
        return unique
    }

    func rename(_ title: String) {
        customTitle = title.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(customTitle, forKey: "accountTitle.\(id)")
    }
}

@MainActor @Observable
final class Session {
    /// Accounts that signed in. `stored` is the Keychain truth; an account that is offline stays stored but has no state.
    private(set) var states: [AccountState] = []
    private(set) var stored: [Account] = []
    private(set) var unreachable: [UUID: String] = [:]
    private(set) var isRestoring = true
    /// Recently viewed, across accounts, newest first. Jira's own history can't be merged across sites.
    private(set) var history: [IssueTarget] = []
    /// Issues starred in Conductor, newest first. Local only: Jira has no issue stars.
    private(set) var stars: [Star] = (try? JSONDecoder().decode([Star].self, from: UserDefaults.standard.data(forKey: "stars") ?? Data())) ?? []

    /// One-shot requests from menu commands, URLs and other windows; the root view consumes them.
    var createIssueRequested = false
    var navigationRequest: ListFilters?
    var pendingOpen: IssueTarget?
    var focusSearchRequested = false
    var reloadTick = 0
    var addAccountRequested = false

    var isSignedIn: Bool { !states.isEmpty }
    var accounts: [Account] { stored }

    func state(_ id: UUID) -> AccountState? { states.first { $0.id == id } }
    func state(host: String) -> AccountState? { states.first { $0.host.caseInsensitiveCompare(host) == .orderedSame } }
    /// The client that can fetch a given URL with the right credentials; any client for public hosts.
    func client(for url: URL) -> JiraClient? { state(host: url.host() ?? "")?.client ?? states.first?.client }

    // MARK: Lifecycle

    func restore() async {
        watchConnectivity()
        defer { isRestoring = false }
        history = (try? JSONDecoder().decode([IssueTarget].self, from: UserDefaults.standard.data(forKey: "history") ?? Data())) ?? []
        #if DEBUG
        // Dev convenience: CONDUCTOR_SITE/EMAIL/TOKEN (and _2, _3…) skip the login form; nothing is persisted.
        let env = ProcessInfo.processInfo.environment
        let envAccounts: [Account] = ["", "_2", "_3"].compactMap { n in
            guard let site = env["CONDUCTOR_SITE\(n)"].flatMap(Account.normalizeSite), let email = env["CONDUCTOR_EMAIL\(n)"], let token = env["CONDUCTOR_TOKEN\(n)"] else { return nil }
            return Account(site: site, email: email, token: token)
        }
        if !envAccounts.isEmpty {
            stored = envAccounts
            await connectAll(persist: false)
            return
        }
        #endif
        stored = Keychain.load()
        await connectAll(persist: true)
    }

    /// Shows every account from its cache at once, then verifies each token and refreshes in the background.
    private func connectAll(persist: Bool) async {
        var pending: [(Account, AccountState, Task<(any Error)?, Never>)] = []
        for account in stored {
            let st = AccountState(account: account)
            if st.loadCached() { attach(st) }
            let task = Task<(any Error)?, Never> { @MainActor in
                do { try await st.load(); return nil } catch { return error }
            }
            pending.append((account, st, task))
        }
        isRestoring = false // whatever is cached is on screen now; the rest arrives as it verifies
        for (account, st, task) in pending {
            let failure = await task.value
            if failure == nil {
                attach(st)
            } else if let e = failure as? JiraError, e.status == 401 {
                // Never forget an account on its own: a captive portal or proxy can answer 401 for every site.
                unreachable[account.id] = "Sign-in was rejected. Check the API token, then retry."
            } else if states.contains(where: { $0.id == st.id }) {
                st.error = failure?.localizedDescription
            } else {
                unreachable[account.id] = failure?.localizedDescription ?? "Unknown error"
            }
        }
        // Restore never writes the Keychain: a read that failed (a rebuilt dev binary is a different app to the
        // Keychain) would otherwise save an empty list and wipe every account. Add and remove save for themselves.
    }

    /// Adds a state to the live list, keeping the stored order and dealing a colour the first time.
    private func attach(_ st: AccountState) {
        guard !states.contains(where: { $0.id == st.id }) else { return }
        if st.colorName.isEmpty { st.setColor(Palette.next(avoiding: states.map(\.colorName))) }
        states.append(st)
        let order = stored.map(\.id)
        states.sort { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
    }

    /// Adds (or re-adds) an account after validating it.
    @discardableResult
    func add(_ account: Account, persist: Bool = true) async throws -> AccountState {
        let st = AccountState(account: account)
        try await st.load()
        if st.colorName.isEmpty { st.setColor(Palette.next(avoiding: states.map(\.colorName))) }
        states.removeAll { $0.account.site == account.site && $0.account.email == account.email }
        stored.removeAll { $0.site == account.site && $0.email == account.email }
        states.append(st)
        stored.append(account)
        unreachable[account.id] = nil
        if persist { Keychain.save(stored) }
        return st
    }

    func retry(_ account: Account) async {
        do { try await add(account) } catch { unreachable[account.id] = error.localizedDescription }
    }

    func remove(_ account: Account) {
        if let host = account.site.host() { Spotlight.forget(host: host) }
        states.removeAll { $0.id == account.id }
        stored.removeAll { $0.id == account.id }
        unreachable[account.id] = nil
        history.removeAll { $0.accountID == account.id }
        Keychain.save(stored)
    }

    func refreshAll() async {
        let tasks = states.map { st in Task { @MainActor in await st.refreshCatalog(); await st.prefetchLists() } }
        for t in tasks { await t.value }
    }

    /// Tries the network again; when it answers, every list and open issue reloads.
    func reconnect() async {
        await refreshAll()
        for account in accounts where unreachable[account.id] != nil { await retry(account) }
        if !Connectivity.shared.isOffline { reloadTick += 1 }
    }

    /// While offline, retries every 20 s so a dropped VPN or a sleeping laptop recovers on its own.
    private func watchConnectivity() {
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                if Connectivity.shared.isOffline { await reconnect() }
            }
        }
    }

    // MARK: Sidebar presets

    /// Filters the user saved from the list, shown in the sidebar under their account (or All Accounts).
    private(set) var customPresets: [CustomPreset] = (try? JSONDecoder().decode([CustomPreset].self, from: UserDefaults.standard.data(forKey: "customPresets") ?? Data())) ?? []
    /// Built-in entries the user hid; Settings brings them all back.
    private(set) var hiddenPresets: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hiddenPresets") ?? [])

    /// The list a Go menu shortcut opens: unified when several accounts are signed in.
    func filters(for smart: Smart) -> ListFilters? {
        if states.count > 1, smart != .recent { return smart.filters(account: nil) }
        return states.first.map { smart.filters(account: $0.id) }
    }

    /// One sidebar section's entries: the built-in lists, the user's own, and an account's Jira favourite filters.
    func presets(account st: AccountState?) -> [Preset] {
        let id = st?.id
        let prefix = id?.uuidString ?? "all"
        // Recently Viewed stays per account: Jira's history can't be merged across sites.
        var list = Smart.allCases.filter { st != nil || $0 != .recent }
            .map { Preset(id: "\(prefix):\($0.rawValue)", name: $0.title, symbol: $0.symbol, filters: $0.filters(account: id)) }
        list += customPresets.filter { $0.filters.account == id }
            .map { Preset(id: $0.id.uuidString, name: $0.name, symbol: "bookmark", filters: $0.filters, custom: true) }
        if let st {
            list += st.filters.map { f in
                var fl = ListFilters()
                fl.account = st.id
                fl.jiraFilter = f
                fl.status = .any   // the filter's own JQL decides what shows
                return Preset(id: "\(prefix):filter:\(f.id)", name: f.name, symbol: "line.3.horizontal.decrease.circle", filters: fl)
            }
        }
        return list.filter { !hiddenPresets.contains($0.id) }
    }

    /// The sidebar entry these filters came from, for the window title.
    func title(for f: ListFilters) -> String {
        if let key = f.project, let st = f.account.flatMap(state) { return st.projects.first { $0.key == key }?.name ?? key }
        return (presets(account: nil) + states.flatMap { presets(account: $0) }).first { $0.filters == f }?.name ?? "Issues"
    }

    func addPreset(name: String, filters: ListFilters) {
        customPresets.append(CustomPreset(id: UUID(), name: name, filters: filters))
        savePresets()
    }

    func renamePreset(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let i = customPresets.firstIndex(where: { $0.id.uuidString == id }) else { return }
        customPresets[i].name = name
        savePresets()
    }

    func removePreset(_ id: String) {
        customPresets.removeAll { $0.id.uuidString == id }
        savePresets()
    }

    func hidePreset(_ id: String) {
        hiddenPresets.insert(id)
        UserDefaults.standard.set(Array(hiddenPresets).sorted(), forKey: "hiddenPresets")
    }

    func showHiddenPresets() {
        hiddenPresets = []
        UserDefaults.standard.removeObject(forKey: "hiddenPresets")
    }

    private func savePresets() { UserDefaults.standard.set(try? JSONEncoder().encode(customPresets), forKey: "customPresets") }

    func isStarred(_ t: IssueTarget) -> Bool {
        guard let host = state(t.accountID)?.host else { return false }
        return stars.contains { $0.host == host && $0.key == t.key }
    }

    func toggleStar(_ t: IssueTarget, summary: String) {
        guard let host = state(t.accountID)?.host else { return }
        if isStarred(t) { stars.removeAll { $0.host == host && $0.key == t.key } }
        else { stars.insert(Star(host: host, key: t.key, summary: summary), at: 0) }
        UserDefaults.standard.set(try? JSONEncoder().encode(stars), forKey: "stars")
    }

    /// Starred issues of signed-in accounts, as targets.
    var starredTargets: [(target: IssueTarget, summary: String)] {
        stars.compactMap { s in state(host: s.host).map { (IssueTarget(accountID: $0.id, key: s.key), s.summary) } }
    }

    func recordView(_ target: IssueTarget) {
        history.removeAll { $0 == target }
        history.insert(target, at: 0)
        history = Array(history.prefix(100))
        UserDefaults.standard.set(try? JSONEncoder().encode(history), forKey: "history")
    }

    // MARK: Recent searches

    var recentSearches: [String] { UserDefaults.standard.stringArray(forKey: "recentSearches") ?? [] }

    func recordSearch(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > 1 else { return }
        var list = recentSearches.filter { $0 != t }
        list.insert(t, at: 0)
        UserDefaults.standard.set(Array(list.prefix(10)), forKey: "recentSearches")
    }

    func clearRecentSearches() { UserDefaults.standard.removeObject(forKey: "recentSearches") }

    // MARK: Deep links

    /// Handles `conductor://issue/KEY`, `conductor://open?url=…` and plain Jira browse URLs.
    func open(url: URL) {
        var target = url
        if url.scheme == "conductor" {
            if url.host() == "issue" {
                if let st = states.first { pendingOpen = IssueTarget(accountID: st.id, key: url.lastPathComponent.uppercased()) }
                return
            }
            guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
                  let inner = URL(string: raw) else { return }
            target = inner
        }
        guard let key = Self.issueKey(in: target), let st = state(host: target.host() ?? "") ?? states.first else { return }
        pendingOpen = IssueTarget(accountID: st.id, key: key)
    }

    /// Spotlight results carry "host|KEY".
    func open(spotlightID: String) {
        let parts = spotlightID.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let st = state(host: parts[0]) else { return }
        pendingOpen = IssueTarget(accountID: st.id, key: parts[1])
    }

    /// "…/browse/ES-123" or "…?selectedIssue=ES-123" → "ES-123".
    nonisolated static func issueKey(in url: URL) -> String? {
        let parts = url.pathComponents
        if let i = parts.firstIndex(of: "browse"), i + 1 < parts.count { return parts[i + 1].uppercased() }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "selectedIssue" })?.value { return v.uppercased() }
        return nil
    }
}

struct CustomPreset: Codable, Identifiable {
    let id: UUID
    var name: String
    var filters: ListFilters
}

/// Keyed by host rather than account id: ids of accounts from the environment change every launch.
struct Star: Codable, Hashable, Sendable {
    let host: String
    let key: String
    var summary: String
}

extension EnvironmentValues {
    /// The account a view is working in. Set by the list, issue, create and board views for their children.
    @Entry var jira: AccountState? = nil
}

/// The boring system colours, which is the point: they read well on glass in both appearances.
enum Palette {
    /// Menu order; defaults are dealt from `dealOrder` so neighbouring accounts contrast.
    static let names = ["blue", "indigo", "purple", "pink", "red", "orange", "yellow", "green", "mint", "teal", "cyan", "brown", "gray"]
    private static let dealOrder = ["blue", "green", "orange", "purple", "pink", "teal", "red", "yellow", "indigo", "mint", "cyan", "brown", "gray"]

    static func color(named name: String) -> Color {
        switch name {
        case "indigo": .indigo
        case "purple": .purple
        case "pink": .pink
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "mint": .mint
        case "teal": .teal
        case "cyan": .cyan
        case "brown": .brown
        case "gray": .gray
        default: .blue
        }
    }

    /// A filled disc as a real (non-template) image, so menus show the colour instead of a monochrome glyph.
    @MainActor static func swatch(_ name: String, size: CGFloat = 14) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor(color(named: name)).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    static func next(avoiding used: [String]) -> String {
        dealOrder.first { !used.contains($0) } ?? dealOrder[used.count % dealOrder.count]
    }
}


// MARK: - Connectivity

/// Whether Jira is reachable, judged from every request's outcome. Reads fail quietly while offline
/// (the cached copy stays on screen and the sidebar says so); writes still report their error.
@MainActor @Observable
final class Connectivity {
    static let shared = Connectivity()
    /// Sites whose last request failed in transport. Per host, so one dead site cannot flap the flag
    /// while another keeps answering.
    private(set) var offlineHosts: Set<String> = []
    var isOffline: Bool { !offlineHosts.isEmpty }

    func report(_ error: any Error, host: String) { if error.isOffline { offlineHosts.insert(host) } }
    func reportSuccess(host: String) { offlineHosts.remove(host) }
}

extension Error {
    /// A transport failure, as opposed to something Jira answered.
    var isOffline: Bool {
        guard let e = self as? URLError else { return false }
        return [.timedOut, .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                .dnsLookupFailed, .secureConnectionFailed, .internationalRoamingOff].contains(e.code)
    }
}
