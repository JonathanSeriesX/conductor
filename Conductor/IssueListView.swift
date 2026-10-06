import SwiftUI

@MainActor @Observable
final class IssueListStore {
    var issues: [Issue] = []
    var nextToken: String?
    var isLoading = false
    var error: String?
    private var jql = ""

    func load(_ client: JiraClient, jql: String) async {
        self.jql = jql
        nextToken = nil
        issues = []
        await fetch(client)
    }

    func loadMore(_ client: JiraClient) async {
        guard nextToken != nil, !isLoading else { return }
        await fetch(client)
    }

    private func fetch(_ client: JiraClient) async {
        isLoading = true
        defer { isLoading = false }
        let requested = jql
        do {
            let page = try await client.search(jql: jql, nextPageToken: nextToken)
            guard requested == jql else { return } // a newer query superseded this one
            issues += page.issues
            nextToken = page.isLast == true ? nil : page.nextPageToken
        } catch {
            guard requested == jql else { return }
            self.error = error.localizedDescription
        }
    }
}

struct IssueListView: View {
    let source: Source
    @Binding var selection: String?
    @Environment(Session.self) private var session
    @State private var store = IssueListStore()
    @State private var search = ""

    private var jql: String { source.jql(search: search) }

    var body: some View {
        List(selection: $selection) {
            ForEach(store.issues) { issue in
                IssueRow(issue: issue)
                    .tag(issue.key)
                    .onAppear {
                        if issue.id == store.issues.last?.id, let c = session.client {
                            Task { await store.loadMore(c) }
                        }
                    }
            }
            if store.isLoading {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .overlay {
            if !store.isLoading, store.issues.isEmpty {
                ContentUnavailableView(search.isEmpty ? "No issues" : "No matches", systemImage: "tray")
            }
        }
        .navigationTitle(source.title)
        .navigationSubtitle(store.issues.isEmpty ? "" : "\(store.issues.count)\(store.nextToken == nil ? "" : "+") issues")
        .searchable(text: $search, placement: .toolbar, prompt: "Search or JQL")
        .task(id: jql) {
            // Debounce typing; JQL is evaluated server-side.
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled, let c = session.client else { return }
            await store.load(c, jql: jql)
        }
        .refreshable { if let c = session.client { await store.load(c, jql: jql) } }
        .errorAlert($store.error)
    }
}

struct IssueRow: View {
    let issue: Issue

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RemoteImage(url: issue.fields.issuetype.iconUrl, placeholder: "circle")
                .frame(width: 16, height: 16)
                .padding(.top, 2)
                .help(issue.fields.issuetype.name)
            VStack(alignment: .leading, spacing: 5) {
                Text(issue.fields.summary).lineLimit(2)
                HStack(spacing: 8) {
                    Text(issue.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                    StatusPill(status: issue.fields.status)
                    Spacer(minLength: 0)
                    if let p = issue.fields.priority { PriorityIcon(priority: p) }
                    Avatar(user: issue.fields.assignee, size: 18)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
