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
    private var customTitle: String

    nonisolated var id: UUID { account.id }
    var host: String { account.site.host() ?? "" }
    /// The user's own name for the account, else the company from the email domain ("epicstar.net" → "Epicstar"),
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

    init(account: Account) {
        self.account = account
        client = JiraClient(account: account)
        customTitle = UserDefaults.standard.string(forKey: "accountTitle.\(account.id)") ?? ""
    }

    /// Validates the token, then loads the catalog (cached copy first).
    func load() async throws {
        me = try await client.myself()
        client.sprintField = try? await client.sprintFieldId()
        projects = DiskCache.load(account: account, name: "projects") ?? []
        filters = DiskCache.load(account: account, name: "filters") ?? []
        await refreshCatalog()
    }

    func refreshCatalog() async {
        async let p = client.projects()
        async let f = client.favouriteFilters()
        async let t = client.issueTypes()
        async let a = client.jqlAutocomplete()
        if let fresh = try? await p { projects = fresh; DiskCache.save(fresh, account: account, name: "projects") }
        if let fresh = try? await f { filters = fresh; DiskCache.save(fresh, account: account, name: "filters") }
        starred = Set(UserDefaults.standard.stringArray(forKey: starredKey) ?? [])
            .union(projects.filter { $0.favourite == true }.map(\.key))
        issueTypeNames = Array(Set(((try? await t) ?? []).map(\.name))).sorted()
        jqlFields = (try? await a)?.visibleFieldNames ?? []
    }

    private var starredKey: String { "starred.\(host)|\(account.email)" }

    func toggleStar(_ project: Project) {
        if starred.contains(project.key) { starred.remove(project.key) } else { starred.insert(project.key) }
        UserDefaults.standard.set(Array(starred).sorted(), forKey: starredKey)
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

    /// One-shot requests from menu commands, URLs and other windows; the root view consumes them.
    var createIssueRequested = false
    var navigationRequest: Source?
    var pendingOpen: IssueTarget?
    var focusSearchRequested = false
    var reloadTick = 0

    var isSignedIn: Bool { !states.isEmpty }
    var accounts: [Account] { stored }

    func state(_ id: UUID) -> AccountState? { states.first { $0.id == id } }
    func state(host: String) -> AccountState? { states.first { $0.host.caseInsensitiveCompare(host) == .orderedSame } }
    /// The client that can fetch a given URL with the right credentials; any client for public hosts.
    func client(for url: URL) -> JiraClient? { state(host: url.host() ?? "")?.client ?? states.first?.client }

    // MARK: Lifecycle

    func restore() async {
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

    /// Signs every stored account in, in parallel, keeping sidebar order.
    private func connectAll(persist: Bool) async {
        let pending = stored.map { account -> (Account, AccountState, Task<(any Error)?, Never>) in
            let st = AccountState(account: account)
            let task = Task<(any Error)?, Never> { @MainActor in
                do { try await st.load(); return nil } catch { return error }
            }
            return (account, st, task)
        }
        for (account, st, task) in pending {
            let failure = await task.value
            if failure == nil {
                states.append(st)
            } else if let e = failure as? JiraError, e.status == 401 {
                stored.removeAll { $0.id == account.id } // the token is dead; forget it
            } else {
                unreachable[account.id] = failure?.localizedDescription ?? "Unknown error"
            }
        }
        if persist { Keychain.save(stored) }
    }

    /// Adds (or re-adds) an account after validating it.
    @discardableResult
    func add(_ account: Account, persist: Bool = true) async throws -> AccountState {
        let st = AccountState(account: account)
        try await st.load()
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
        let tasks = states.map { st in Task { @MainActor in await st.refreshCatalog() } }
        for t in tasks { await t.value }
    }

    // MARK: Navigation helpers

    /// The smart list to show for a shortcut: unified when several accounts are signed in.
    func source(for smart: Smart) -> Source? {
        if states.count > 1, smart != .recent { return .all(smart) }
        return states.first.map { .smart(smart, $0.id) }
    }

    /// Resolves a `Source.id` once the catalog is loaded.
    func source(for id: String) -> Source? {
        let parts = id.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        if parts[0] == "all" { return Smart(rawValue: parts[1]).map(Source.all) }
        guard let uuid = UUID(uuidString: parts[0]), let st = state(uuid) else { return nil }
        switch parts[1] {
        case "project": return parts.count == 3 ? st.projects.first { $0.key == parts[2] }.map { .project($0, uuid) } : nil
        case "filter": return parts.count == 3 ? st.filters.first { $0.id == parts[2] }.map { .filter($0, uuid) } : nil
        default: return Smart(rawValue: parts[1]).map { .smart($0, uuid) }
        }
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

extension EnvironmentValues {
    /// The account a view is working in. Set by the list, issue, create and board views for their children.
    @Entry var jira: AccountState? = nil
}
