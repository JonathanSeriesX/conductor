import SwiftUI

/// One save on the issue's History tab: who, when, and the fields it changed.
struct ChangeGroup: Codable, Hashable, Sendable, Identifiable {
    struct Item: Codable, Hashable, Sendable {
        let field: String
        let fromString: String?
        let toString: String?
    }
    let id: String
    let author: JiraUser?
    let created: Date
    let items: [Item]
}

struct ChangelogPage: Codable, Sendable {
    let values: [ChangeGroup]
    let isLast: Bool?
}

/// The issue's history as Jira keeps it, newest first, in a window of its own like the Bin.
struct HistoryView: View {
    let target: IssueTarget
    @Environment(Session.self) private var session
    @State private var groups: [ChangeGroup]?
    @State private var error: String?

    var body: some View {
        Group {
            if let groups, groups.isEmpty {
                ContentUnavailableView("No changes yet", systemImage: "clock.arrow.circlepath")
            } else if let groups {
                List(groups) { g in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Avatar(user: g.author, size: 18)
                            Text(g.author?.displayName ?? String(localized: "Jira")).font(.callout.weight(.semibold))
                            Spacer()
                            Text(g.created.formatted(.relative(presentation: .named))).font(.caption)
                                .foregroundStyle(.tertiary).help(g.created.formatted())
                        }
                        ForEach(Array(g.items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(item.field.prefix(1).uppercased() + item.field.dropFirst())
                                    .foregroundStyle(.secondary).frame(width: 120, alignment: .trailing)
                                if let from = item.fromString, !from.isEmpty {
                                    Text(from).strikethrough().foregroundStyle(.secondary).lineLimit(2)
                                    Image(systemName: "arrow.forward").font(.caption).foregroundStyle(.tertiary)
                                        .flipsForRightToLeftLayoutDirection(true)
                                }
                                Text(item.toString ?? "").lineLimit(3)
                            }
                            .font(.callout)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollContentBackground(.hidden)
            } else if error == nil {
                ProgressView()
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .background(Backdrop())
        .navigationTitle(Text("History of \(target.key)"))
        .task {
            guard let c = session.state(target.accountID)?.client else { return }
            do { groups = try await c.changelog(target.key) } catch { self.error = error.localizedDescription }
        }
        .errorAlert($error)
    }
}
