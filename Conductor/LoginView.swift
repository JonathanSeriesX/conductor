import SwiftUI

struct LoginView: View {
    @Environment(Session.self) private var session
    @State private var site = ""
    @State private var email = ""
    @State private var token = ""
    @State private var error: String?

    private var canSubmit: Bool {
        Credentials.normalizeSite(site) != nil && email.contains("@") && !token.isEmpty && !session.isBusy
    }

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 18) {
                Image(systemName: "ticket.fill")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(.linearGradient(colors: [.indigo, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text("Conductor").font(.largeTitle.weight(.semibold))
                Text("Sign in to Jira Cloud with an API token.").foregroundStyle(.secondary)

                VStack(spacing: 10) {
                    TextField("Site", text: $site, prompt: Text("yourteam.atlassian.net"))
                    TextField("Email", text: $email, prompt: Text("you@company.com"))
                    SecureField("API token", text: $token, prompt: Text("API token"))
                }
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit { if canSubmit { submit() } }

                if let error {
                    Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
                }

                Button(action: submit) {
                    if session.isBusy { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
                    else { Text("Sign In").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(!canSubmit)
                .keyboardShortcut(.defaultAction)

                Link("Create an API token at id.atlassian.com", destination: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!)
                    .font(.footnote)
            }
            .padding(32)
            .frame(width: 400)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
        }
    }

    private func submit() {
        guard let url = Credentials.normalizeSite(site) else { return }
        error = nil
        Task {
            do { try await session.signIn(Credentials(site: url, email: email.trimmingCharacters(in: .whitespaces), token: token.trimmingCharacters(in: .whitespaces))) }
            catch { self.error = error.localizedDescription }
        }
    }
}
