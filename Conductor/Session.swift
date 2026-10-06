import SwiftUI

@MainActor @Observable
final class Session {
    private(set) var accounts: [Account] = []
    private(set) var active: Account?
    private(set) var client: JiraClient?
    private(set) var me: JiraUser?
    private(set) var projects: [Project] = []
    private(set) var filters: [Filter] = []
    /// Starred project keys for the active account. Jira has no public write API for stars,
    /// so this is local, seeded with whatever is starred on the Jira side.
    private(set) var starred: Set<String> = []
    var isBusy = false
    private(set) var isRestoring = true

    var isSignedIn: Bool { client != nil }

    func restore() async {
        defer { isRestoring = false }
        #if DEBUG
        // Dev convenience: CONDUCTOR_SITE/EMAIL/TOKEN (and _2, _3…) skip the login form; nothing is persisted.
        let env = ProcessInfo.processInfo.environment
        let envAccounts: [Account] = ["", "_2", "_3"].compactMap { n in
            guard let site = env["CONDUCTOR_SITE\(n)"].flatMap(Account.normalizeSite), let email = env["CONDUCTOR_EMAIL\(n)"], let token = env["CONDUCTOR_TOKEN\(n)"] else { return nil }
            return Account(site: site, email: email, token: token)
        }
        if let first = envAccounts.first {
            accounts = envAccounts
            try? await signIn(first, persist: false)
            return
        }
        #endif
        accounts = Keychain.load()
        let lastID = UserDefaults.standard.string(forKey: "activeAccount").flatMap(UUID.init)
        guard let account = accounts.first(where: { $0.id == lastID }) ?? accounts.first else { return }
        do { try await signIn(account, persist: false) }
        catch let e as JiraError where e.status == 401 { remove(account) }
        catch { /* offline: keep the account, user can retry */ }
    }

    /// Validates the token, makes the account active and (optionally) remembers it.
    func signIn(_ account: Account, persist: Bool = true) async throws {
        isBusy = true
        defer { isBusy = false }
        var c = JiraClient(account: account)
        let user = try await c.myself()
        c.sprintField = try? await c.sprintFieldId()
        if persist {
            accounts.removeAll { $0.site == account.site && $0.email == account.email }
            accounts.append(account)
            Keychain.save(accounts)
        }
        UserDefaults.standard.set(account.id.uuidString, forKey: "activeAccount")
        active = account
        me = user
        client = c
        projects = []
        filters = []
        await refreshCatalog()
        #if DEBUG
        print("Conductor: signed in to \(account.site.host() ?? "?") as \(user.displayName); \(projects.count) projects, \(filters.count) filters")
        #endif
    }

    func refreshCatalog() async {
        guard let client else { return }
        async let p = client.projects()
        async let f = client.favouriteFilters()
        projects = (try? await p) ?? []
        filters = (try? await f) ?? []
        starred = Set(UserDefaults.standard.stringArray(forKey: starredKey) ?? [])
            .union(projects.filter { $0.favourite == true }.map(\.key))
    }

    var starredProjects: [Project] { projects.filter { starred.contains($0.key) } }

    func toggleStar(_ project: Project) {
        if starred.contains(project.key) { starred.remove(project.key) } else { starred.insert(project.key) }
        UserDefaults.standard.set(Array(starred).sorted(), forKey: starredKey)
    }

    private var starredKey: String { "starred.\(active?.site.host() ?? "")|\(active?.email ?? "")" }

    /// Forgets an account; if it was active, falls over to the next one.
    func remove(_ account: Account) {
        accounts.removeAll { $0.id == account.id }
        Keychain.save(accounts)
        guard active?.id == account.id else { return }
        active = nil
        client = nil
        me = nil
        projects = []
        filters = []
        if let next = accounts.first { Task { try? await signIn(next, persist: false) } }
    }

    func signOut() { if let active { remove(active) } }
}
