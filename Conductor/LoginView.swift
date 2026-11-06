import SwiftUI

struct LoginView: View {
    /// Adds an account to those signed in: the sidebar's sheet, or the window Settings opens. `dismiss` closes
    /// either on Cancel and Add, never the main window.
    var isSheet = false
    /// A new token for this account, Jira having rejected its own: the site and the user stay as they are.
    var updating: Account?
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var site = ""
    @State private var email = ""
    @State private var token = ""
    @State private var error: String?

    @State private var busy = false
    @FocusState private var editingSite: Bool
    private var server: Bool {
        Account.normalizeSite(site).map { Account(site: $0, email: "", token: "").isServer } ?? false
    }
    private var canSubmit: Bool {
        Account.normalizeSite(site) != nil && (server || email.contains("@")) && !token.isEmpty && !busy
    }

    var body: some View {
        // As a window the card is the window: a background behind it, not a backdrop that fills a frame.
        if isSheet { card } else { card.padding(.top, 8).background(Backdrop()) }
    }

    private var card: some View {
        VStack(spacing: 18) {
            Image(systemName: "ticket.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(
                    .linearGradient(colors: [.indigo, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(title).font(.largeTitle.weight(.semibold))
            Text(
                server
                    ? "Sign in to Jira Server or Data Center with a personal access token."
                    : "Sign in to Jira Cloud with an API token."
            )
            .foregroundStyle(.secondary).multilineTextAlignment(.center)

            VStack(spacing: 10) {
                TextField("Site", text: $site, prompt: Text("yourteam.atlassian.net")).disabled(updating != nil)
                    .focused($editingSite)
                // A personal access token names its user itself, so a Server site has no username field. While the
                // site is typed it stays, greyed, or "acme." (a Server until ".atlassian.net") would make it blink.
                if !server || editingSite {
                    TextField(
                        server ? "Username" : "Email", text: server ? .constant("") : $email,
                        prompt: server ? Text("Taken from the token") : Text(verbatim: "you@company.com")
                    )
                    .disabled(server || updating != nil)
                }
                SecureField(
                    server ? "Personal access token" : "API token", text: $token,
                    prompt: Text(server ? "Personal access token" : "API token"))
            }
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .onSubmit { if canSubmit { submit() } }

            if let error {
                Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
            } else if !isSheet, Keychain.isUnavailable {
                // Accounts may be stored but unreadable (a denied prompt): say so rather than look signed out.
                Text("Couldn't read the Keychain (error \(Int(Keychain.lastStatus))).")
                    .font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            HStack {
                if isSheet {
                    Button("Cancel") { dismiss() }.glassButton().controlSize(.large).keyboardShortcut(.cancelAction)
                }
                Button(action: submit) {
                    if busy {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    } else {
                        Text(updating != nil ? "Update" : isSheet ? "Add" : "Sign In").frame(maxWidth: .infinity)
                    }
                }
                .glassButton(prominent: true)
                .controlSize(.large)
                .disabled(!canSubmit)
                .keyboardShortcut(.defaultAction)
            }

            if server, let url = Account.normalizeSite(site) {
                Link(
                    "Create a personal access token in your Jira profile",
                    destination: url.appending(path: "secure/ViewProfile.jspa").appending(queryItems: [
                        URLQueryItem(
                            name: "selectedTab",
                            value: "com.atlassian.pats.pats-plugin:jira-user-personal-access-tokens")
                    ])
                )
                .font(.footnote)
            } else {
                Link(
                    "Create an API token at id.atlassian.com",
                    destination: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!
                )
                .font(.footnote)
            }

            // Only the free GitHub build says so; the App Store build is the commercial license itself.
            #if GITHUB_BUILD
                if !isSheet {
                    HStack(spacing: 4) {
                        Text("Free for non-commercial use").foregroundStyle(.secondary)
                        Text(verbatim: "·").foregroundStyle(.secondary)
                        // ponytail: the README's License section until the App Store record exists; then apps.apple.com/app/id….
                        Link(
                            "Buy on the App Store",
                            destination: URL(string: "https://github.com/JonathanSeriesX/conductor#license")!)
                    }
                    .font(.footnote)
                }
            #endif
        }
        .padding(32)
        .frame(width: 400)
        // Signed in, or about to be: the list window takes over. The system restores this card from a launch that
        // had no account, and only the main window checks the accounts, so it waited for good with none sent; and
        // an account the 20 s retry brings back after an offline launch now returns the list.
        .onChange(of: !isSheet && (session.isSignedIn || session.isRestoring), initial: true) { _, takeOver in
            guard takeOver else { return }
            // A turn later: by then a main window the system restores beside the card is there, and a card dismissed
            // in the turn it appeared stayed open.
            Task {
                // Closed windows stay in the list: only one on screen or in the Dock counts.
                if !NSApp.windows.contains(where: {
                    $0.identifier?.rawValue.hasPrefix("main") == true && ($0.isVisible || $0.isMiniaturized)
                }) {
                    openWindow(id: "main")
                }
                dismissWindow(id: "login")
            }
        }
        .onAppear {
            guard let updating else { return }
            site = updating.site.absoluteString
            // A Server account's email is its username, which the greyed field does not show.
            if !updating.isServer { email = updating.email }
        }
    }

    private var title: LocalizedStringKey {
        guard updating == nil else { return server ? "Update Personal Access Token" : "Update API Token" }
        return isSheet ? "Add Account" : "Conductor"
    }

    private func submit() {
        guard let url = Account.normalizeSite(site) else { return }
        error = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                let token = token.trimmingCharacters(in: .whitespaces)
                var url = url
                var account = Account(site: url, email: email.trimmingCharacters(in: .whitespaces), token: token)
                if account.isServer {
                    let me: JiraUser
                    do { me = try await JiraClient(account: account).myself() } catch {
                        // https is tried first; a site typed without a scheme that speaks no TLS gets one try over http.
                        guard let http = Account.plainHTTPSite(site, after: error) else { throw error }
                        url = http
                        account = Account(site: url, email: account.email, token: token)
                        me = try await JiraClient(account: account).myself()
                    }
                    account = Account(site: url, email: me.accountId, token: token)
                }
                // A Server token names its own user: another one's would sign this account in as them.
                if let updating, account.id != updating.id {
                    self.error = String(localized: "This token belongs to another user.")
                    return
                }
                try await session.add(account)
                // The first account: the onChange above hands the card over to the list window.
                if isSheet { dismiss() }
            } catch { self.error = error.localizedDescription }
        }
    }
}

extension Account {
    /// Opens the sign-in card for a new token: the sidebar's menu and error mark, and a list that is empty for it.
    var updateTokenTitle: String {
        isServer ? String(localized: "Update Personal Access Token…") : String(localized: "Update API Token…")
    }
}
