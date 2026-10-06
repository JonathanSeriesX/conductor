import SwiftUI

enum Source: Hashable {
    case assignedToMe, reportedByMe, recent
    case project(Project)
    case filter(Filter)

    var title: String {
        switch self {
        case .assignedToMe: "Assigned to me"
        case .reportedByMe: "Reported by me"
        case .recent: "Recently viewed"
        case .project(let p): p.name
        case .filter(let f): f.name
        }
    }

    private var whereClause: String {
        switch self {
        case .assignedToMe: "assignee = currentUser() AND statusCategory != Done"
        case .reportedByMe: "reporter = currentUser()"
        case .recent: "issuekey IN issueHistory()"
        case .project(let p): "project = \(p.key)"
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

    /// Final JQL for this source plus the search box contents.
    func jql(search: String) -> String {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return "\(whereClause) ORDER BY \(orderClause)" }
        if q.range(of: #"(?i)(=|~|\bin\b|\bis\b|order by)"#, options: .regularExpression) != nil { return q }
        if q.range(of: #"^[A-Za-z][A-Za-z0-9_]+-\d+$"#, options: .regularExpression) != nil { return "key = \(q.uppercased())" }
        let escaped = q.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\(whereClause) AND text ~ \"\(escaped)\" ORDER BY \(orderClause)"
    }
}

struct SidebarView: View {
    @Environment(Session.self) private var session
    @Binding var selection: Source?

    var body: some View {
        List(selection: $selection) {
            Section("For You") {
                Label("Assigned to me", systemImage: "person.crop.circle").tag(Source.assignedToMe)
                Label("Reported by me", systemImage: "square.and.pencil").tag(Source.reportedByMe)
                Label("Recently viewed", systemImage: "clock").tag(Source.recent)
            }
            if !session.filters.isEmpty {
                Section("Favourite Filters") {
                    ForEach(session.filters) { f in
                        Label(f.name, systemImage: "line.3.horizontal.decrease.circle").tag(Source.filter(f))
                    }
                }
            }
            Section("Projects") {
                ForEach(session.projects) { p in
                    Label {
                        Text(p.name)
                    } icon: {
                        RemoteImage(url: p.avatar, placeholder: "folder")
                            .frame(width: 18, height: 18)
                            .clipShape(.rect(cornerRadius: 4))
                    }
                    .tag(Source.project(p))
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Conductor")
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        .refreshable { await session.refreshCatalog() }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                Avatar(user: session.me, size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.me?.displayName ?? "").font(.callout.weight(.medium)).lineLimit(1)
                    Text(session.client?.credentials.site.host() ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Menu {
                    Button("Refresh projects") { Task { await session.refreshCatalog() } }
                    Divider()
                    Button("Sign Out", role: .destructive) { session.signOut() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(10)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            .padding(10)
        }
    }
}
