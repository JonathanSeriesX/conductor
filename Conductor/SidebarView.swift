import SwiftUI

/// The one query behind the list. Every sidebar entry is a preset of it; the chips edit it in place.
struct ListFilters: Hashable, Codable {
    enum Scope: String, CaseIterable, Codable { case all = "Everything", recent = "Recently viewed", watching = "Watching" }
    enum Status: String, CaseIterable, Codable { case any = "Any status", open = "Open", todo = "To Do", inProgress = "In Progress", done = "Done" }
    enum Assignee: String, CaseIterable, Codable { case any = "Any assignee", me = "Assigned to me", unassigned = "Unassigned" }
    enum Reporter: String, CaseIterable, Codable { case any = "Any reporter", me = "Reported by me" }
    enum Updated: String, CaseIterable, Codable { case any = "Any time", today = "Today", week = "This week", month = "This month" }

    struct Sort: Hashable, Codable {
        enum Field: String, CaseIterable, Codable {
            case updated = "Updated", created = "Created", viewed = "Last viewed", due = "Due date", priority = "Priority", key = "Key"
            var jql: String {
                switch self {
                case .updated: "updated"
                case .created: "created"
                case .viewed: "lastViewed"
                case .due: "duedate"
                case .priority: "priority"
                case .key: "key"
                }
            }
        }
        var field: Field = .updated
        var descending = true
        var clause: String { "\(field.jql) \(descending ? "DESC" : "ASC")" }

        /// Client-side counterpart of `clause`, for merging pages from several sites into one list.
        func areInOrder(_ a: Issue, _ b: Issue) -> Bool {
            let r: ComparisonResult
            switch field {
            case .updated, .viewed: r = (a.fields.updated ?? .distantPast).compare(b.fields.updated ?? .distantPast)
            case .created: r = (a.fields.created ?? .distantPast).compare(b.fields.created ?? .distantPast)
            case .due: r = (a.fields.duedate ?? "").compare(b.fields.duedate ?? "")   // "2026-10-31": sorts as text
            case .priority:
                // Jira's priority ids count up from the highest, so "priority DESC" is the lowest id first.
                let (pa, pb) = (Int(a.fields.priority?.id ?? "") ?? .max, Int(b.fields.priority?.id ?? "") ?? .max)
                r = pa == pb ? .orderedSame : pa < pb ? .orderedDescending : .orderedAscending
            case .key: r = a.key.localizedStandardCompare(b.key)
            }
            if r == .orderedSame { return a.key < b.key }
            return descending ? r == .orderedDescending : r == .orderedAscending
        }
    }

    /// nil: every signed-in account, with a site badge on each row.
    var account: UUID?
    /// A project key and a Jira favourite filter: both belong to one account, so they clear when the account changes.
    var project: String?
    var jiraFilter: Filter?
    var scope: Scope = .all
    /// Every list starts on Open unless the Hide Done setting is off; the chip changes it per list.
    var status: Status = (UserDefaults.standard.object(forKey: "hideDone") as? Bool ?? true) ? .open : .any
    var assignee: Assignee = .any
    var reporter: Reporter = .any
    var type: String?
    var updated: Updated = .any
    var sort = Sort()
    /// The search box: free text, an issue key, or raw JQL.
    var text = ""

    var isActive: Bool { self != ListFilters() }
    var isRawJQL: Bool { Self.looksLikeJQL(text) }

    static func looksLikeJQL(_ q: String) -> Bool {
        q.range(of: #"(?i)(=|~|\bin\b|\bis\b|order by)"#, options: .regularExpression) != nil
    }

    private var query: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isKey: Bool { query.range(of: #"^[A-Za-z][A-Za-z0-9_]+-\d+$"#, options: .regularExpression) != nil }

    /// Jira refuses a search with no restriction at all ("unbounded"), so the list says so instead of asking.
    var isBounded: Bool { isRawJQL || isKey || !restrictions.isEmpty }

    /// JQL for one account.
    var jql: String {
        if isRawJQL { return query }
        if isKey { return "key = \"\(query.uppercased())\"" }
        let c = restrictions
        return (c.isEmpty ? "" : c.joined(separator: " AND ") + " ") + "ORDER BY " + sort.clause
    }

    private var restrictions: [String] {
        let q = query
        var c: [String] = []
        if let f = jiraFilter { c.append("filter = \(f.id)") }
        // Keys like IN or AND are JQL reserved words, hence the quotes.
        if let project { c.append("project = \"\(project)\"") }
        switch scope {
        case .all: break
        case .recent: c.append("issuekey IN issueHistory()")
        case .watching: c.append("watcher = currentUser()")
        }
        switch status {
        case .any: break
        case .open: c.append("statusCategory != Done")
        default: c.append("statusCategory = \"\(status.rawValue)\"")
        }
        switch assignee {
        case .any: break
        case .me: c.append("assignee = currentUser()")
        case .unassigned: c.append("assignee IS EMPTY")
        }
        if reporter == .me { c.append("reporter = currentUser()") }
        if let type { c.append("issuetype = \"\(type)\"") }
        switch updated {
        case .any: break
        case .today: c.append("updated >= startOfDay()")
        case .week: c.append("updated >= startOfWeek()")
        case .month: c.append("updated >= startOfMonth()")
        }
        if !q.isEmpty {
            let escaped = q.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            c.append("text ~ \"\(escaped)\"")
        }
        return c
    }
}

/// The built-in sidebar entries. Unified across accounts, or per account.
enum Smart: String, CaseIterable, Codable {
    case assigned, reported, recent, watching

    var title: String {
        switch self {
        case .assigned: "Assigned to Me"
        case .reported: "Reported by Me"
        case .recent: "Recently Viewed"
        case .watching: "Watching"
        }
    }

    var symbol: String {
        switch self {
        case .assigned: "person.crop.circle"
        case .reported: "square.and.pencil"
        case .recent: "clock"
        case .watching: "eye"
        }
    }

    func filters(account: UUID?) -> ListFilters {
        var f = ListFilters()
        f.account = account
        switch self {
        case .assigned: f.assignee = .me
        case .reported: f.reporter = .me; f.sort.field = .created
        case .recent: f.scope = .recent; f.status = .any; f.sort.field = .viewed
        case .watching: f.scope = .watching
        }
        return f
    }
}

/// A sidebar entry: a name for one `ListFilters`.
struct Preset: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
    let filters: ListFilters
    /// Saved by the user from the list, so it can be renamed and deleted; built-in ones can only be hidden.
    var custom = false
}

struct SidebarView: View {
    @Environment(Session.self) private var session
    @Environment(\.openWindow) private var openWindow
    @Environment(\.appearsActive) private var active
    @Binding var selection: ListFilters?
    @State private var showAddAccount = false
    @State private var collapsed: Set<UUID> = []
    @State private var expandedAllProjects: Set<UUID> = []
    @State private var renaming: AccountState?
    @State private var renamingPreset: Preset?
    @State private var newTitle = ""
    @State private var signingOut: AccountState?
    @State private var deletingPreset: Preset?

    var body: some View {
        List(selection: $selection) {
            if session.states.count > 1 {
                Section("All Accounts") {
                    ForEach(session.presets(account: nil)) { presetRow($0, color: nil) }
                }
            }
            ForEach(session.states) { st in
                Section(isExpanded: expandedBinding(st)) {
                    accountContent(st)
                } header: {
                    HStack(spacing: 4) {
                        Text(st.title)
                        if let e = st.error {
                            Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange).help("Showing cached data. \(e)")
                        }
                    }
                        .contextMenu {
                            Button("Rename…", systemImage: "pencil") { newTitle = st.title; renaming = st }
                            Menu("Colour") {
                                ForEach(Palette.names, id: \.self) { name in
                                    Toggle(isOn: Binding(get: { st.colorName == name }, set: { if $0 { st.setColor(name) } })) {
                                        Label { Text(name.capitalized) } icon: { Image(nsImage: Palette.swatch(name)) }
                                    }
                                }
                            }
                            Button("Refresh", systemImage: "arrow.clockwise") { Task { try? await st.load() } }
                            Divider()
                            Button("Sign Out of \(st.title)…", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { signingOut = st }
                        }
                }
            }
            ForEach(session.accounts.filter { session.unreachable[$0.id] != nil }, id: \.id) { account in
                Section(account.site.host() ?? "Account") {
                    Label("Couldn't connect", systemImage: "wifi.exclamationmark").foregroundStyle(.secondary)
                        .help(session.unreachable[account.id] ?? "")
                    Button("Retry") { Task { await session.retry(account) } }
                    Button("Remove Account", role: .destructive) { session.remove(account) }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Conductor")
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        // A safe-area bar gets the system scroll-edge blur, so no opaque `.bar` backing is needed under the button.
        .safeAreaBar(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                if Connectivity.shared.isOffline {
                    HStack {
                        Label("Working Offline", systemImage: "wifi.slash").foregroundStyle(.secondary)
                        Spacer()
                        Button { Task { await session.reconnect() } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Try to reconnect now. Conductor also retries on its own every 20 seconds.")
                    }
                }
                let warming = session.states.filter { $0.warmProgress != nil && $0.warmIsFirst }
                if !warming.isEmpty {
                    // One bar for every account: the first download of an account, or a catch-up after launch.
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: warming.map { $0.warmProgress ?? 0 }.reduce(0, +) / Double(warming.count))
                            .progressViewStyle(.linear).controlSize(.small)
                        Text(warming.count == 1 ? warming[0].warmLabel : "Downloading issues for \(warming.count) accounts…")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Button { showAddAccount = true } label: { Label("Add Account", systemImage: "plus") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Sign in to another Jira site")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .sheet(isPresented: $showAddAccount) { LoginView(isSheet: true) }
        .onChange(of: session.addAccountRequested) { _, on in if on { showAddAccount = true; session.addAccountRequested = false } }
        .alert("Rename Account", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newTitle)
            Button("Rename") { renaming?.rename(newTitle); renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Shown as the section title in the sidebar.")
        }
        .confirmationDialog("Sign out of \(signingOut?.title ?? "")?", isPresented: Binding(get: { signingOut != nil }, set: { if !$0 { signingOut = nil } }), titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { if let st = signingOut { session.remove(st.account) }; signingOut = nil }
            Button("Cancel", role: .cancel) { signingOut = nil }
        } message: {
            Text("The token is removed from the Keychain. Cached issues stay until the cache is cleared.")
        }
        .confirmationDialog("Delete the filter “\(deletingPreset?.name ?? "")”?", isPresented: Binding(get: { deletingPreset != nil }, set: { if !$0 { deletingPreset = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let p = deletingPreset { session.removePreset(p.id) }; deletingPreset = nil }
            Button("Cancel", role: .cancel) { deletingPreset = nil }
        }
        .alert("Rename Filter", isPresented: Binding(get: { renamingPreset != nil }, set: { if !$0 { renamingPreset = nil } })) {
            TextField("Name", text: $newTitle)
            Button("Rename") { if let p = renamingPreset { session.renamePreset(p.id, to: newTitle) }; renamingPreset = nil }
            Button("Cancel", role: .cancel) { renamingPreset = nil }
        }
        #if DEBUG
        .task {
            guard ProcessInfo.processInfo.environment["CONDUCTOR_SHOW"] == "addAccount" else { return }
            try? await Task.sleep(for: .seconds(1))
            showAddAccount = true
        }
        #endif
    }

    @ViewBuilder
    private func accountContent(_ st: AccountState) -> some View {
        ForEach(session.presets(account: st)) { presetRow($0, color: st.color) }
        ForEach(st.starredProjects) { projectRow($0, st) }
        DisclosureGroup(isExpanded: Binding(
            get: { expandedAllProjects.contains(st.id) },
            set: { if $0 { expandedAllProjects.insert(st.id) } else { expandedAllProjects.remove(st.id) } }
        )) {
            ForEach(st.projects) { projectRow($0, st) }
        } label: {
            tinted("All Projects", symbol: "folder", color: st.color)
        }
    }

    private func presetRow(_ p: Preset, color: Color?) -> some View {
        tinted(p.name, symbol: p.symbol, color: color)
            .tag(p.filters)
            .contextMenu {
                if p.custom {
                    Button("Rename…", systemImage: "pencil") { newTitle = p.name; renamingPreset = p }
                    Button("Delete…", systemImage: "trash", role: .destructive) { deletingPreset = p }
                } else {
                    Button("Hide", systemImage: "eye.slash") { session.hidePreset(p.id) }
                }
            }
    }

    /// A sidebar label whose icon carries the account colour; unified entries take the accent from the system.
    /// Every icon goes grey with the window, as the system's own do.
    private func tinted(_ title: String, symbol: String, color: Color?) -> some View {
        Label { Text(title) } icon: {
            if let color { Image(systemName: symbol).foregroundStyle(active ? color : .secondary) }
            else { Image(systemName: symbol) }
        }
    }

    private func expandedBinding(_ st: AccountState) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(st.id) }, set: { if $0 { collapsed.remove(st.id) } else { collapsed.insert(st.id) } })
    }

    private func projectRow(_ p: Project, _ st: AccountState) -> some View {
        var filters = ListFilters()
        filters.account = st.id
        filters.project = p.key
        return Label {
            Text(p.name)
        } icon: {
            RemoteImage(url: p.avatar, placeholder: "folder")
                .frame(width: 18, height: 18)
                .clipShape(.rect(cornerRadius: 4))
                .grayscale(active ? 0 : 1).opacity(active ? 1 : 0.5)
        }
        .tag(filters)
        .onTapGesture(count: 2) { openWindow(id: "board", value: BoardTarget(accountID: st.id, projectKey: p.key)) }
        .contextMenu {
            Button("Open Board", systemImage: "rectangle.split.3x1") { openWindow(id: "board", value: BoardTarget(accountID: st.id, projectKey: p.key)) }
            Button("Open on Web", systemImage: "safari") { NSWorkspace.shared.open(st.client.boardURL(project: p.key)) }
            Button("New Issue in \(p.name)…", systemImage: "plus") { selection = filters; session.createIssueRequested = true }
        }
    }
}
