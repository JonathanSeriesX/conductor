import SwiftUI

/// Markdown text editor with @mention autocomplete. `mentions` collects display name → accountId
/// so the converter can turn "@Name" into real mention nodes.
struct Composer: View {
    @Binding var text: String
    @Binding var mentions: [String: String]
    var placeholder = "Write something…"
    var minHeight: CGFloat = 60
    var maxHeight: CGFloat = 260
    var showHint = true
    /// Lets the owner move focus into the editor, e.g. from the Add Comment menu item.
    var focus: FocusState<Bool>.Binding?
    @FocusState private var ownFocus: Bool
    @Environment(\.jira) private var jira
    @State private var candidates: [JiraUser] = []
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $text)
                .focused(focus ?? $ownFocus)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: minHeight, maxHeight: maxHeight)
                .padding(6)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder).foregroundStyle(.tertiary)
                            .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                    }
                }
            if !candidates.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(candidates) { u in
                        Button { accept(u) } label: {
                            HStack(spacing: 8) {
                                Avatar(user: u, size: 18)
                                Text(u.displayName)
                                Spacer()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .glassEffect(.regular, in: .rect(cornerRadius: 10))
                .transition(.opacity)
            }
            if showHint {
                Text(verbatim: "**bold**   *italic*   `code`   - list   > quote   @mention")
                    .font(.caption2).foregroundStyle(.quaternary)
            }
        }
        .onChange(of: text) { _, new in
            // A trailing "@name" drives the suggestion list; anything else dismisses it.
            if let m = new.firstMatch(of: /@([\p{L}\p{N}][\p{L}\p{N} .'-]{0,30})$/) { query = String(m.1) }
            else { query = ""; candidates = [] }
        }
        .task(id: query) {
            guard !query.isEmpty, let c = jira?.client else { return }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let found = (try? await c.users(matching: query)) ?? []
            withAnimation(.easeOut(duration: 0.15)) { candidates = Array(found.filter { $0.active != false }.prefix(5)) }
        }
    }

    private func accept(_ user: JiraUser) {
        guard let r = text.range(of: "@" + query, options: .backwards) else { return }
        text.replaceSubrange(r, with: "@\(user.displayName) ")
        mentions[user.displayName] = user.accountId
        candidates = []
        query = ""
    }
}

/// Lays children out left to right, wrapping like text.
struct Wrap: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: width == .infinity ? maxX : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct Chip: View {
    let text: String
    var onRemove: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 4) {
            Text(text)
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.quaternary.opacity(0.6), in: .capsule)
    }
}

/// Searchable list of people assignable to an issue or within a project.
struct PeoplePicker: View {
    enum Scope { case issue(String), project(String) }
    let scope: Scope
    let current: JiraUser?
    var onPick: (JiraUser?) -> Void
    @Environment(\.jira) private var jira
    @State private var query = ""
    @State private var users: [JiraUser] = []

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search people", text: $query).textFieldStyle(.roundedBorder)
            List {
                if let me = jira?.me, me.accountId != current?.accountId {
                    Button { onPick(me) } label: { Label("Assign to me", systemImage: "person.fill.checkmark") }
                }
                if current != nil {
                    Button { onPick(nil) } label: { Label("Unassigned", systemImage: "person.slash") }
                }
                ForEach(users) { u in
                    Button { onPick(u) } label: {
                        HStack { Avatar(user: u, size: 20); Text(u.displayName); Spacer()
                            if u.accountId == current?.accountId { Image(systemName: "checkmark").foregroundStyle(.secondary) } }
                    }
                }
            }
            .buttonStyle(.plain)
            .listStyle(.plain)
        }
        .padding(10)
        .frame(width: 280, height: 320)
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let c = jira?.client else { return }
            switch scope {
            case .issue(let key): users = (try? await c.assignableUsers(key, query: query)) ?? []
            case .project(let key): users = (try? await c.assignableUsers(project: key, query: query)) ?? []
            }
        }
    }
}
