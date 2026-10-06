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
        // Show the last result for this query instantly, then replace it.
        issues = DiskCache.load(account: client.account, name: "list-" + DiskCache.hash(jql)) ?? []
        await fetch(client, replacing: true)
    }

    func loadMore(_ client: JiraClient) async {
        guard nextToken != nil, !isLoading else { return }
        await fetch(client, replacing: false)
    }

    private func fetch(_ client: JiraClient, replacing: Bool) async {
        isLoading = true
        defer { isLoading = false }
        let requested = jql
        do {
            let page = try await client.search(jql: jql, nextPageToken: nextToken)
            guard requested == jql else { return } // a newer query superseded this one
            issues = replacing ? page.issues : issues + page.issues
            nextToken = page.isLast == true ? nil : page.nextPageToken
            if replacing { DiskCache.save(page.issues, account: client.account, name: "list-" + DiskCache.hash(jql)) }
            Spotlight.index(page.issues, host: client.account.site.host() ?? "")
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
    @Environment(\.openWindow) private var openWindow
    @State private var store = IssueListStore()
    @State private var search = ""
    @State private var filters = ListFilters()
    @State private var suggestions: [(display: String, completion: String)] = []
    @State private var savingFilter = false
    @State private var filterName = ""
    @FocusState private var searchFocused: Bool

    private var jql: String { source.jql(search: search, filters: filters) }
    private var isRawJQL: Bool { Source.looksLikeJQL(search) }

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
        .safeAreaInset(edge: .top, spacing: 0) { chips }
        .overlay {
            if !store.isLoading, store.issues.isEmpty {
                ContentUnavailableView(search.isEmpty && !filters.isActive ? "No issues" : "No matches", systemImage: "tray")
            }
        }
        .navigationTitle(source.title)
        .navigationSubtitle(store.issues.isEmpty ? "" : "\(store.issues.count)\(store.nextToken == nil ? "" : "+") issues")
        .searchable(text: $search, placement: .toolbar, prompt: "Search, JQL, or paste a Jira link")
        .searchFocused($searchFocused)
        .searchSuggestions {
            ForEach(suggestions, id: \.completion) { s in
                Text(s.display).searchCompletion(s.completion)
            }
        }
        .onSubmit(of: .search) {
            if let url = URL(string: search), url.scheme?.hasPrefix("http") == true, Session.issueKey(in: url) != nil {
                session.open(url: url)
                search = ""
                return
            }
            session.recordSearch(search)
        }
        .toolbar {
            ToolbarItemGroup {
            Group {
                if case .project(let p) = source {
                    Button { openWindow(id: "board", value: p.key) } label: { Label("Board", systemImage: "rectangle.split.3x1") }
                        .help("Open the project board")
                }
                if !search.isEmpty {
                    Button { filterName = ""; savingFilter = true } label: { Label("Save as Filter", systemImage: "bookmark") }
                        .help("Save this search as a favourite filter")
                }
                }
                .labelStyle(.titleAndIcon)
            }
        }
        .alert("Save as Filter", isPresented: $savingFilter) {
            TextField("Filter name", text: $filterName)
            Button("Save") { saveFilter() }.disabled(filterName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The filter is starred and shows up in the sidebar on every device.")
        }
        .task(id: "\(jql)#\(session.reloadTick)") {
            // Debounce typing; JQL is evaluated server-side.
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled, let c = session.client else { return }
            await store.load(c, jql: jql)
        }
        .task(id: search) { await updateSuggestions() }
        .onChange(of: session.focusSearchRequested) { _, on in
            if on { searchFocused = true; session.focusSearchRequested = false }
        }
        .errorAlert($store.error)
    }

    // MARK: Chips

    private var chips: some View {
        HStack(spacing: 6) {
            chip(filters.status.rawValue, active: filters.status != .any) {
                ForEach(ListFilters.Status.allCases, id: \.self) { s in Button(s.rawValue) { filters.status = s } }
            }
            chip(filters.assignee.rawValue, active: filters.assignee != .any) {
                ForEach(ListFilters.Assignee.allCases, id: \.self) { a in Button(a.rawValue) { filters.assignee = a } }
            }
            chip(filters.type ?? "Any type", active: filters.type != nil) {
                Button("Any type") { filters.type = nil }
                Divider()
                ForEach(session.issueTypeNames, id: \.self) { t in Button(t) { filters.type = t } }
            }
            chip(filters.updated.rawValue, active: filters.updated != .any) {
                ForEach(ListFilters.Updated.allCases, id: \.self) { u in Button(u.rawValue) { filters.updated = u } }
            }
            if filters.isActive {
                Button { filters = ListFilters() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Clear filters")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .disabled(isRawJQL)
        .opacity(isRawJQL ? 0.4 : 1)
        .help(isRawJQL ? "Filters don't apply to raw JQL" : "")
    }

    private func chip<M: View>(_ title: String, active: Bool, @ViewBuilder _ items: () -> M) -> some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 3) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(active ? Color.white : .primary)
            .background(active ? Color.accentColor : Color.primary.opacity(0.07), in: .capsule)
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
    }

    // MARK: Search assist

    private func updateSuggestions() async {
        let q = search
        if q.isEmpty {
            suggestions = session.recentSearches.map { ($0, $0) }
            return
        }
        guard isRawJQL || session.jqlFields.contains(where: { q.lowercased().hasPrefix($0.value.lowercased()) }) else { suggestions = []; return }
        // "status = In" → values for status; "sta" → field names.
        if let m = q.firstMatch(of: /(.*?)([A-Za-z_][\w\[\]. ]*?)\s*(=|!=|~|!~|>=|<=|>|<|\bin\b|\bnot in\b|\bis not\b|\bis\b)\s*("?)([^"]*)$/.ignoresCase()) {
            let field = String(m.2).trimmingCharacters(in: .whitespaces)
            let partial = String(m.5)
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let c = session.client else { return }
            let values = (try? await c.jqlSuggestions(field: field, value: partial)) ?? []
            let prefix = String(m.1) + field + " " + String(m.3) + " "
            suggestions = values.prefix(8).map { ($0.displayName.replacingOccurrences(of: "<b>", with: "").replacingOccurrences(of: "</b>", with: ""), prefix + $0.value + " ") }
            return
        }
        guard let last = q.split(separator: " ", omittingEmptySubsequences: false).last else { suggestions = []; return }
        let head = q.dropLast(last.count)
        let word = last.lowercased()
        guard !word.isEmpty else { suggestions = []; return }
        suggestions = session.jqlFields
            .filter { $0.value.lowercased().hasPrefix(word) }
            .prefix(8)
            .map { ($0.displayName, head + $0.value + " ") }
    }

    private func saveFilter() {
        guard let c = session.client else { return }
        let name = filterName.trimmingCharacters(in: .whitespaces)
        let jql = self.jql
        Task {
            do {
                let f = try await c.createFilter(name: name, jql: jql)
                search = ""
                await session.refreshCatalog()
                session.navigationRequest = .filter(f)
            } catch { store.error = error.localizedDescription }
        }
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
