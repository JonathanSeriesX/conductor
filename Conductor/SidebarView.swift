import SwiftUI

enum Source: Hashable {
    case assignedToMe, reportedByMe, recent, watching
    case project(Project)
    case filter(Filter)

    var title: String {
        switch self {
        case .assignedToMe: "Assigned to me"
        case .reportedByMe: "Reported by me"
        case .recent: "Recently viewed"
        case .watching: "Watching"
        case .project(let p): p.name
        case .filter(let f): f.name
        }
    }

    /// Stable string for scene restoration and settings.
    var id: String {
        switch self {
        case .assignedToMe: "assigned"
        case .reportedByMe: "reported"
        case .recent: "recent"
        case .watching: "watching"
        case .project(let p): "project:\(p.key)"
        case .filter(let f): "filter:\(f.id)"
        }
    }

    private var whereClause: String {
        switch self {
        case .assignedToMe: "assignee = currentUser() AND statusCategory != Done"
        case .reportedByMe: "reporter = currentUser()"
        case .recent: "issuekey IN issueHistory()"
        case .watching: "watcher = currentUser() AND statusCategory != Done"
        case .project(let p):
            // Keys like IN or AND are JQL reserved words, hence the quotes.
            UserDefaults.standard.bool(forKey: "hideDoneInProjects") ? "project = \"\(p.key)\" AND statusCategory != Done" : "project = \"\(p.key)\""
        case .filter(let f): "filter = \(f.id)"
        }
    }

    private var orderClause: String {
        switch self {
        case .reportedByMe: "created DESC"
        case .recent: "lastViewed DESC"
        default: "updated DESC"
        }
    }

    static func looksLikeJQL(_ q: String) -> Bool {
        q.range(of: #"(?i)(=|~|\bin\b|\bis\b|order by)"#, options: .regularExpression) != nil
    }

    /// Final JQL for this source plus the search box contents and filter chips.
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
    @AppStorage("sidebar.starredExpanded") private var starredExpanded = true
    @AppStorage("sidebar.allExpanded") private var allExpanded = false // companies have dozens; starred is the working set

    var body: some View {
        List(selection: $selection) {
            Section("For You") {
                Label("Assigned to me", systemImage: "person.crop.circle").tag(Source.assignedToMe)
                Label("Reported by me", systemImage: "square.and.pencil").tag(Source.reportedByMe)
                Label("Recently viewed", systemImage: "clock").tag(Source.recent)
                Label("Watching", systemImage: "eye").tag(Source.watching)
            }
            if !session.filters.isEmpty {
                Section("Favourite Filters") {
                    ForEach(session.filters) { f in
                        Label(f.name, systemImage: "line.3.horizontal.decrease.circle").tag(Source.filter(f))
                    }
                }
            }
            if !session.starredProjects.isEmpty {
                Section("Starred Projects", isExpanded: $starredExpanded) {
                    ForEach(session.starredProjects) { projectRow($0) }
                }
            }
            Section("All Projects", isExpanded: $allExpanded) {
                ForEach(session.projects) { projectRow($0) }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Conductor")
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                Avatar(user: session.me, size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.me?.displayName ?? "").font(.callout.weight(.medium)).lineLimit(1)
                    Text(session.active?.site.host() ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Menu {
                    if session.accounts.count > 1 {
                        Section("Switch Account") {
                            ForEach(session.accounts) { a in
                                Button { Task { try? await session.signIn(a, persist: false) } } label: {
                                    if a.id == session.active?.id { Label(a.label, systemImage: "checkmark") } else { Text(a.label) }
                                }
                                .disabled(a.id == session.active?.id)
                            }
                        }
                    }
                    Button("Add Account…") { showAddAccount = true }
                    Button("Refresh Projects") { Task { await session.refreshCatalog() } }
                    Divider()
                    Button("Sign Out of \(session.active?.site.host() ?? "Jira")", role: .destructive) { session.signOut() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Accounts and sign out")
            }
            .padding(10)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            .padding(10)
        }
        .sheet(isPresented: $showAddAccount) { LoginView(isSheet: true) }
        #if DEBUG
        .task {
            guard ProcessInfo.processInfo.environment["CONDUCTOR_SHOW"] == "addAccount" else { return }
            try? await Task.sleep(for: .seconds(1))
            showAddAccount = true
        }
        #endif
    }

    private func projectRow(_ p: Project) -> some View {
        let starred = session.starred.contains(p.key)
        return Label {
            Text(p.name)
        } icon: {
            RemoteImage(url: p.avatar, placeholder: "folder")
                .frame(width: 18, height: 18)
                .clipShape(.rect(cornerRadius: 4))
        }
        .tag(Source.project(p))
        .contextMenu {
            Button(starred ? "Unstar" : "Star", systemImage: starred ? "star.slash" : "star") { session.toggleStar(p) }
            Button("Open Board", systemImage: "rectangle.split.3x1") { openWindow(id: "board", value: p.key) }
            Button("New Issue in \(p.name)…", systemImage: "plus") { session.createIssueRequested = true; selection = .project(p) }
        }
    }
}
