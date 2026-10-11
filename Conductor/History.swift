import SwiftUI

/// One save on the issue's History tab: who, when, and the fields it changed.
struct ChangeGroup: Codable, Hashable, Sendable, Identifiable {
    struct Item: Codable, Hashable, Sendable {
        let field: String
        let fromString: String?
        let toString: String?
        /// Jira's raw values: seconds for time fields, "2026-10-18" for a due date.
        var from: String?
        var to: String?
    }
    let id: String
    let author: JiraUser?
    let created: Date
    let items: [Item]
}

extension ChangeGroup.Item {
    /// Jira's own bookkeeping rather than a change anyone made: a work log's id beside its time, the board order,
    /// or a value written over with itself ("0m → 0m" when an estimate is first set).
    var isNoise: Bool { ["worklogid", "rank"].contains(field.lowercased()) || shownFrom == shownTo }

    /// The field as the issue page names it.
    var label: String {
        switch field.lowercased() {
        case "status": String(localized: "Status")
        case "assignee": String(localized: "Assignee")
        case "reporter": String(localized: "Reporter")
        case "priority": String(localized: "Priority")
        case "issuetype": String(localized: "Type")
        case "summary": String(localized: "Summary")
        case "description": String(localized: "Description")
        case "labels": String(localized: "Labels")
        case "duedate": String(localized: "Due date")
        case "sprint": String(localized: "Sprint")
        case "story points", "story point estimate": String(localized: "Story Points")
        case "parent", "issueparentassociation", "epic link": String(localized: "Parent")
        case "project": String(localized: "Project")
        case "key": String(localized: "Key")
        case "resolution": String(localized: "History.Resolution", defaultValue: "Resolution")
        case "comment": String(localized: "History.Comment", defaultValue: "Comment", comment: "A noun: a comment")
        case "link": String(localized: "History.Link", defaultValue: "Link", comment: "A noun: a link between issues")
        case "attachment": String(localized: "History.Attachment", defaultValue: "Attachment")
        case "timespent": String(localized: "History.TimeSpent", defaultValue: "Time spent")
        case "timeestimate": String(localized: "History.Remaining", defaultValue: "Remaining estimate")
        case "timeoriginalestimate": String(localized: "History.Original", defaultValue: "Original estimate")
        case "worklogtimespent": String(localized: "History.WorkLogged", defaultValue: "Work logged")
        case "fix version": String(localized: "History.FixVersion", defaultValue: "Fix version")
        case "component": String(localized: "History.Component", defaultValue: "Component")
        default: field.prefix(1).uppercased() + field.dropFirst()
        }
    }

    var shownFrom: AttributedString? { shown(fromString, raw: from) }
    var shownTo: AttributedString? { shown(toString, raw: to) }

    /// A value as the issue page writes it: "1h 30m" for seconds, a date for "2026-10-18 00:00:00.0", and wiki
    /// markup (Jira keeps texts in it here) as the formatting it stands for.
    private func shown(_ text: String?, raw: String?) -> AttributedString? {
        switch field.lowercased() {
        case "timespent", "timeestimate", "timeoriginalestimate", "worklogtimespent":
            guard let seconds = Int(raw ?? text ?? "") else { break }
            return AttributedString(LogWorkView.format(seconds))
        case "duedate":
            guard let day = (raw ?? text).flatMap({ DueDate.parse(String($0.prefix(10))) }) else { break }
            return AttributedString(day.formatted(date: .abbreviated, time: .omitted))
        case "description", "comment", "environment":
            return text.map(Self.fromWiki)
        default: break
        }
        return text.map { AttributedString($0) }
    }

    /// Jira wiki markup as formatted text: *bold*, _italic_, -struck-, {{code}}, [label|url], headings, lists,
    /// panels and images. ponytail: tables and colours come out as their text; enough for a line of history.
    static func fromWiki(_ wiki: String) -> AttributedString {
        var s = wiki
        let rules: [(String, String)] = [
            (#"\{(code|noformat|quote|panel|color)[^}]*\}"#, ""),
            (#"(?m)^h[1-6]\.\s*"#, ""),
            (#"(?m)^[*#-]+\s+"#, "• "),
            (#"!([^|!\n]+)(\|[^!\n]*)?!"#, "$1"),
            (#"\[~accountid:[^\]]+\]"#, "@…"),
            (#"\[([^|\]\n]+)\|([^\]\n]+)\]"#, "[$1]($2)"),
            (#"\{\{(.+?)\}\}"#, "`$1`"),
            (#"(?<![\w*])\*(\S(?:[^*\n]*\S)?)\*(?![\w*])"#, "**$1**"),
            (#"(?<![\w_])_(\S(?:[^_\n]*\S)?)_(?![\w_])"#, "*$1*"),
            (#"(?<![\w-])-(\S(?:[^-\n]*\S)?)-(?![\w-])"#, "~~$1~~"),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(wiki)
    }
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
    @State private var failed = false

    var body: some View {
        Group {
            if let groups, groups.isEmpty {
                ContentUnavailableView("No changes yet", systemImage: "clock.arrow.circlepath")
            } else if let groups {
                // Saves that changed only Jira's bookkeeping (a work log's id) are left out.
                List(groups.filter { $0.items.contains { !$0.isNoise } }) { g in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Avatar(user: g.author, size: 18)
                            Text(g.author?.displayName ?? String(localized: "Jira")).font(.callout.weight(.semibold))
                            Spacer()
                            Text(g.created.formatted(.relative(presentation: .named))).font(.caption)
                                .foregroundStyle(.tertiary).help(g.created.formatted())
                        }
                        ForEach(Array(g.items.filter { !$0.isNoise }.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(item.label).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(
                                    .trailing
                                )
                                .frame(width: 120, alignment: .trailing)
                                // Struck through alone, a value removed; with an arrow, one replaced.
                                let to = item.shownTo.flatMap { $0.characters.isEmpty ? nil : $0 }
                                if let from = item.shownFrom, !from.characters.isEmpty {
                                    Text(from).strikethrough().foregroundStyle(.secondary).lineLimit(2)
                                    if to != nil {
                                        Image(systemName: "arrow.forward").font(.caption).foregroundStyle(.tertiary)
                                            .flipsForRightToLeftLayoutDirection(true)
                                    }
                                }
                                if let to { Text(to).lineLimit(3) }
                            }
                            .font(.callout)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollContentBackground(.hidden)
            } else if failed {
                ContentUnavailableView("Couldn't load \(target.key)", systemImage: "exclamationmark.triangle")
            } else {
                ProgressView()
            }
        }
        // Fill the window from the first frame: sized to its minimum, the spinner's backdrop drew as a box
        // in the middle, and the list's arrival pushed it out to the edges.
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
        .background(Backdrop())
        .navigationTitle(Text("History of \(target.key)"))
        .task {
            guard let st = session.state(target.accountID) else { return }
            let (client, key) = (st.client, target.key)
            // The last copy draws at once; Jira's answer replaces it behind.
            let (now, fresh) = st.memo("changelog-\(key)") { try await client.changelog(key) }
            groups = now
            if let value = await fresh.value { groups = value } else if groups == nil { failed = true }
        }
    }
}
