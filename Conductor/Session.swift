import SwiftUI

@MainActor @Observable
final class Session {
    private(set) var client: JiraClient?
    private(set) var me: JiraUser?
    private(set) var projects: [Project] = []
    private(set) var filters: [Filter] = []
    var isBusy = false
    private(set) var isRestoring = true

    var isSignedIn: Bool { client != nil }

    func restore() async {
        defer { isRestoring = false }
        #if DEBUG
        // Dev convenience: launch with CONDUCTOR_SITE/EMAIL/TOKEN set to skip the login form.
        let env = ProcessInfo.processInfo.environment
        if let site = env["CONDUCTOR_SITE"].flatMap(Credentials.normalizeSite), let email = env["CONDUCTOR_EMAIL"], let token = env["CONDUCTOR_TOKEN"] {
            try? await signIn(Credentials(site: site, email: email, token: token), persist: false)
            return
        }
        #endif
        guard let creds = Keychain.load() else { return }
        do { try await signIn(creds, persist: false) }
        catch let e as JiraError where e.status == 401 { Keychain.clear() }
        catch { /* offline: keep creds, user can retry */ }
    }

    func signIn(_ creds: Credentials, persist: Bool = true) async throws {
        isBusy = true
        defer { isBusy = false }
        var c = JiraClient(credentials: creds)
        let user = try await c.myself()
        c.sprintField = try? await c.sprintFieldId()
        if persist { Keychain.save(creds) }
        me = user
        client = c
        await refreshCatalog()
    }

    func refreshCatalog() async {
        guard let client else { return }
        async let p = client.projects()
        async let f = client.favouriteFilters()
        projects = (try? await p) ?? []
        filters = (try? await f) ?? []
    }

    func signOut() {
        Keychain.clear()
        client = nil
        me = nil
        projects = []
        filters = []
    }
}
