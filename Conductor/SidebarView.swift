import SwiftUI

/// The four lists every account has. Unified across accounts, or per account.
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

    var whereClause: String {
        switch self {
        case .assigned: "assignee = currentUser() AND statusCategory != Done"
        case .reported: "reporter = currentUser()"
        case .recent: "issuekey IN issueHistory()"
        case .watching: "watcher = currentUser() AND statusCategory != Done"
        }
    }

    var orderClause: String {
        switch self {
        case .reported: "created DESC"
        case .recent: "lastViewed DESC"
        default: "updated DESC"
        }
    }
}

enum Source: Hashable {
    case all(Smart)
    case smart(Smart, UUID)
    case project(Project, UUID)
    case filter(Filter, UUID)

    var title: String {
        switch self {
        case .all(let s): s.title
        case .smart(let s, _): s.title
        case .project(let p, _): p.name
        case .filter(let f, _): f.name
        }
    }

    /// Account the list belongs to; nil for unified lists.
    var accountID: UUID? {
        switch self {
        case .all: nil
        case .smart(_, let id), .project(_, let id), .filter(_, let id): id
        }
    }

    var isUnified: Bool { accountID == nil }

    /// Stable string for scene restoration and settings.
    var id: String {
        switch self {
        case .all(let s): "all:\(s.rawValue)"
        case .smart(let s, let id): "\(id):\(s.rawValue)"
        case .project(let p, let id): "\(id):project:\(p.key)"
        case .filter(let f, let id): "\(id):filter:\(f.id)"
        }
    }

    private var whereClause: String {
        switch self {
        case .all(let s), .smart(let s, _): s.whereClause
        case .project(let p, _):
            // Keys like IN or AND are JQL reserved words, hence the quotes.
            UserDefaults.standard.bool(forKey: "hideDoneInProjects") ? "project = \"\(p.key)\" AND statusCategory != Done" : "project = \"\(p.key)\""
        case .filter(let f, _): "filter = \(f.id)"
        }
    }

    private var orderClause: String {
        switch self {
        case .all(let s), .smart(let s, _): s.orderClause
        default: "updated DESC"
        }
    }

    static func looksLikeJQL(_ q: String) -> Bool {
        q.range(of: #"(?i)(=|~|\bin\b|\bis\b|order by)"#, options: .regularExpression) != nil
    }

    /// JQL for this source on one account, with the search box contents and filter chips applied.
    func jql(search: String, filters: ListFilters = ListFilters()) -> String {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.looksLikeJQL(q) { return q }
        if q.range(of: #"^[A-Za-z][A-Za-z0-9_]+-\d+$"#, options: .regularExpression) != nil { return "key = \"\(q.uppercased())\"" }
        var clauses = [whereClause] + filters.clauses
        if !q.isEmpty {
            let escaped = q.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            clauses.append("text ~ \"\(escaped)\"")
        }
        return clauses.joined(separator: " AND ") + " ORDER BY " + orderClause
    }
}

/// Quick filters shown as chips above the issue list.
struct ListFilters: Equatable {
    enum Status: String, CaseIterable { case any = "Any status", todo = "To Do", inProgress = "In Progress", done = "Done" }
    enum Assignee: String, CaseIterable { case any = "Anyone", me = "Me", unassigned = "Unassigned" }
    enum Updated: String, CaseIterable { case any = "Any time", today = "Today", week = "This week", month = "This month" }

    var status: Status = .any
    var assignee: Assignee = .any
    var type: String?
    var updated: Updated = .any

    var isActive: Bool { self != ListFilters() }

    var clauses: [String] {
        var c: [String] = []
        if status != .any { c.append("statusCategory = \"\(status.rawValue)\"") }
        switch assignee {
        case .any: break
        case .me: c.append("assignee = currentUser()")
        case .unassigned: c.append("assignee IS EMPTY")
        }
        if let type { c.append("issuetype = \"\(type)\"") }
        switch updated {
        case .any: break
        case .today: c.append("updated >= startOfDay()")
        case .week: c.append("updated >= startOfWeek()")
        case .month: c.append("updated >= startOfMonth()")
        }
        return c
    }
}

struct SidebarView: View {
    @Environment(Session.self) private var session
    @Environment(\.openWindow) private var openWindow
    @Binding var selection: Source?
    @State private var showAddAccount = false
    @State private var collapsed: Set<UUID> = []
    @State private var expandedAllProjects: Set<UUID> = []
    @State private var renaming: AccountState?
    @State private var newTitle = ""

    var body: some View {
        List(selection: $selection) {
            if session.states.count > 1 {
                Section("All Accounts") {
                    // Recently Viewed stays per account: Jira's history can't be merged across sites.
                    ForEach(Smart.allCases.filter { $0 != .recent }, id: \.self) { s in
                        Label(s.title, systemImage: s.symbol).tag(Source.all(s))
                    }
                }
            }
            ForEach(session.states) { st in
                Section(isExpanded: expandedBinding(st)) {
                    accountContent(st)
                } header: {
                    Text(st.title)
                        .contextMenu {
                            Button("Rename…", systemImage: "pencil") { newTitle = st.title; renaming = st }
                            Button("Refresh Projects", systemImage: "arrow.clockwise") { Task { await st.refreshCatalog() } }
                            Divider()
                            Button("Sign Out of \(st.title)", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { session.remove(st.account) }
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
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { showAddAccount = true } label: { Label("Add Account", systemImage: "plus") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Sign in to another Jira site")
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.bar)
        }
        .sheet(isPresented: $showAddAccount) { LoginView(isSheet: true) }
        .alert("Rename Account", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newTitle)
            Button("Rename") { renaming?.rename(newTitle); renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Shown as the section title in the sidebar.")
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
        ForEach(Smart.allCases, id: \.self) { s in
            Label(s.title, systemImage: s.symbol).tag(Source.smart(s, st.id))
        }
        ForEach(st.filters) { f in
            Label(f.name, systemImage: "line.3.horizontal.decrease.circle").tag(Source.filter(f, st.id))
        }
        ForEach(st.starredProjects) { projectRow($0, st) }
        DisclosureGroup(isExpanded: Binding(
            get: { expandedAllProjects.contains(st.id) },
            set: { if $0 { expandedAllProjects.insert(st.id) } else { expandedAllProjects.remove(st.id) } }
        )) {
            ForEach(st.projects) { projectRow($0, st) }
        } label: {
            Label("All Projects", systemImage: "folder").foregroundStyle(.secondary)
        }
    }

    private func expandedBinding(_ st: AccountState) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(st.id) }, set: { if $0 { collapsed.remove(st.id) } else { collapsed.insert(st.id) } })
    }

    private func projectRow(_ p: Project, _ st: AccountState) -> some View {
        let starred = st.starred.contains(p.key)
        return Label {
            Text(p.name)
        } icon: {
            RemoteImage(url: p.avatar, placeholder: "folder")
                .frame(width: 18, height: 18)
                .clipShape(.rect(cornerRadius: 4))
        }
        .tag(Source.project(p, st.id))
        .contextMenu {
            Button(starred ? "Unstar" : "Star", systemImage: starred ? "star.slash" : "star") { st.toggleStar(p) }
            Button("Open Board", systemImage: "rectangle.split.3x1") { openWindow(id: "board", value: BoardTarget(accountID: st.id, projectKey: p.key)) }
            Button("New Issue in \(p.name)…", systemImage: "plus") { selection = .project(p, st.id); session.createIssueRequested = true }
        }
    }
}
