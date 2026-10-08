import SwiftUI

struct LoginView: View {
    var isSheet = false
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var site = ""
    @State private var email = ""
    @State private var token = ""
    @State private var error: String?

    @State private var busy = false
    private var canSubmit: Bool {
        Account.normalizeSite(site) != nil && email.contains("@") && !token.isEmpty && !busy
    }

    var body: some View {
        if isSheet {
            card
        } else {
            ZStack {
                Backdrop()
                card.glassPane(cornerRadius: 28)
            }
        }
    }

    private var card: some View {
        VStack(spacing: 18) {
            Image(systemName: "ticket.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(
                    .linearGradient(colors: [.indigo, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(isSheet ? "Add Account" : "Conductor").font(.largeTitle.weight(.semibold))
            Text("Sign in to Jira Cloud with an API token.").foregroundStyle(.secondary)

            VStack(spacing: 10) {
                TextField("Site", text: $site, prompt: Text("yourteam.atlassian.net"))
                TextField("Email", text: $email, prompt: Text(verbatim: "you@company.com"))
                SecureField("API token", text: $token, prompt: Text("API token"))
            }
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .onSubmit { if canSubmit { submit() } }

            if let error {
                Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            HStack {
                if isSheet {
                    Button("Cancel") { dismiss() }.glassButton().controlSize(.large).keyboardShortcut(.cancelAction)
                }
                Button(action: submit) {
                    if busy {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    } else {
                        Text(isSheet ? "Add" : "Sign In").frame(maxWidth: .infinity)
                    }
                }
                .glassButton(prominent: true)
                .controlSize(.large)
                .disabled(!canSubmit)
                .keyboardShortcut(.defaultAction)
            }

            Link(
                "Create an API token at id.atlassian.com",
                destination: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!
            )
            .font(.footnote)
        }
        .padding(32)
        .frame(width: 400)
    }

    private func submit() {
        guard let url = Account.normalizeSite(site) else { return }
        error = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                try await session.add(
                    Account(
                        site: url, email: email.trimmingCharacters(in: .whitespaces),
                        token: token.trimmingCharacters(in: .whitespaces)))
                if isSheet { dismiss() }
            } catch { self.error = error.localizedDescription }
        }
    }
}
