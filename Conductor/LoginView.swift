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
                // A personal access token names its user itself, so the username comes from Jira. The field stays,
                // greyed, so the card keeps its height while a typed site turns from Cloud to Server.
                TextField(
                    server ? "Username" : "Email", text: server ? .constant("") : $email,
                    prompt: server ? Text("Taken from the token") : Text(verbatim: "you@company.com")
                )
                .disabled(server || updating != nil)
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
                var account = Account(site: url, email: email.trimmingCharacters(in: .whitespaces), token: token)
                if account.isServer {
                    let me = try await JiraClient(account: account).myself()
                    account = Account(site: url, email: me.accountId, token: token)
                }
                // A Server token names its own user: another one's would sign this account in as them.
                if let updating, account.id != updating.id {
                    self.error = String(localized: "This token belongs to another user.")
                    return
                }
                try await session.add(account)
                if isSheet {
                    dismiss()
                } else {
                    // The first account: the list window takes over from the sign-in card.
                    openWindow(id: "main")
                    dismissWindow(id: "login")
                }
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
