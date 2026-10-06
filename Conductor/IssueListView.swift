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
        .toolbar(id: "list") {
            ToolbarItem(id: "board") {
                if case .project(let p) = source {
                    Button { openWindow(id: "board", value: p.key) } label: { Label("Board", systemImage: "rectangle.split.3x1") }
                        .help("Open the project board")
                }
            }
            ToolbarItem(id: "saveFilter") {
                Button { filterName = ""; savingFilter = true } label: { Label("Save as Filter", systemImage: "bookmark") }
                    .help("Save this search as a favourite filter")
                    .disabled(search.isEmpty)
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

    @State private var openChip: String?

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                FilterChip(id: "status", title: filters.status.rawValue, active: filters.status != .any, open: $openChip) {
                    ForEach(ListFilters.Status.allCases, id: \.self) { s in
                        ChipOption(title: s.rawValue, selected: filters.status == s) { filters.status = s }
                    }
                }
                FilterChip(id: "assignee", title: filters.assignee.rawValue, active: filters.assignee != .any, open: $openChip) {
                    ForEach(ListFilters.Assignee.allCases, id: \.self) { a in
                        ChipOption(title: a.rawValue, selected: filters.assignee == a) { filters.assignee = a }
                    }
                }
                FilterChip(id: "type", title: filters.type ?? "Any type", active: filters.type != nil, open: $openChip) {
                    ChipOption(title: "Any type", selected: filters.type == nil) { filters.type = nil }
                    Divider()
                    ForEach(session.issueTypeNames, id: \.self) { t in
                        ChipOption(title: t, selected: filters.type == t) { filters.type = t }
                    }
                }
                FilterChip(id: "updated", title: filters.updated.rawValue, active: filters.updated != .any, open: $openChip) {
                    ForEach(ListFilters.Updated.allCases, id: \.self) { u in
                        ChipOption(title: u.rawValue, selected: filters.updated == u) { filters.updated = u }
                    }
                }
                if filters.isActive {
                    Button { filters = ListFilters() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Clear filters")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .disabled(isRawJQL)
        .opacity(isRawJQL ? 0.4 : 1)
        .help(isRawJQL ? "Filters don't apply to raw JQL" : "")
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

/// A capsule that opens its options in a popover. While one chip is open, clicking or hovering
/// another chip switches to it straight away, like menus in a menu bar.
struct FilterChip<Options: View>: View {
    let id: String
    let title: String
    let active: Bool
    @Binding var open: String?
    @ViewBuilder let options: () -> Options

    var body: some View {
        Button { open = open == id ? nil : id } label: {
            HStack(spacing: 3) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(active ? Color.white : .primary)
            .background(active ? Color.accentColor : Color.primary.opacity(0.07), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { inside in if inside, open != nil, open != id { open = id } }
        .popover(isPresented: Binding(get: { open == id }, set: { open = $0 ? id : nil }), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 1) { options() }
                .padding(5)
                .frame(minWidth: 170)
        }
    }
}

struct ChipOption: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var hovering = false

    var body: some View {
        Button { action(); dismiss() } label: {
            HStack {
                Text(title)
                Spacer()
                if selected { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(hovering ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
